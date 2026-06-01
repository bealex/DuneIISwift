# Dune II Swift — core engine

A Swift **core game engine** for Westwood's *Dune II: The Building of a Dynasty* v1.07, on **macOS 26** (Apple Silicon). Game logic is **behaviorally faithful** to 1.07 and graphics are **pixel-faithful**; the engine runs **headless** (no renderer/input/audio) for deterministic, sped-up testing. We do not reproduce menus, intros, cutscenes, or the original HUD — the UI is our own multi-window verification UI. Swift 6.3.2, strict concurrency. The renderer uses SpriteKit; the app host (`duneii`) is a **native macOS app (AppKit + SwiftUI), non-Catalyst** (pivoted from Mac Catalyst, 2026-05-31) — a SwiftUI main map window with floating AppKit `NSPanel` tool windows. The core libraries are Foundation-only.

**Read `CurrentState.md` (repo root) first, before anything else.** It is the operational resume point: active task, what was in-flight, the ordered queue of next steps, and the test status. Update it after every task.

After that: `Documentation/Plan.v1.md` is the authoritative plan (goals, locked decisions, phased build); `Documentation/Architecture/Overview.md` is the architecture reference.

## Layout

- `CurrentState.md` (repo root) — operational state. Read first, update after every task.
- `Documentation/`
  - `Plan.v1.md` — the authoritative plan of record.
  - `Architecture/` — `Overview.md` (topology + dependency rules + OpenDUNE constraints), `Testing.md`, `ParityHarness.md`, `FeatureParity.md` (the living gameplay done/not-done table vs OpenDUNE — **keep current**, see Feature workflow step 7).
  - `Formats/` — one markdown per on-disk format (PAK, SHP, WSA, EMC, SAVE, …): own-words description + pointer to the reference C source.
  - `Algorithms/` — Format80 decode, pathfinding, EMC opcode semantics, etc.
  - `History/` — dated changelog, **one file per active day** (`YYYY-MM-DD.md`); `README.md` is the newest-first day index. Append-only.
  - `Insights/` — distilled non-obvious findings, one file per fact; `README.md` indexes them and holds the template.
- `Code/` — the SwiftPM package. Build/test with `cd Code && swift build` / `swift test`. Source trees are organized by kind; each target's directory is set explicitly in `Package.swift` (SPM's default `Sources/` discovery is not used), so adding a target is a new directory under the right tree plus one manifest entry:
  - `Frameworks/` — the `DuneII*` engine libraries, each with its own `CLAUDE.md`. Dependencies point **downward only**; the simulation depends on none of render/input/audio:
    - `DuneIIContracts` — shared vocabulary + seam types: `FrameInfo` (sim→render), `Command` (input→sim), `SoundEvent` (sim→audio), shared IDs/enums. Foundation-only.
    - `DuneIIFormats` — pure `Data`→`Data` decoders/codecs + the EMC disassembler dev tool. Foundation-only.
    - `DuneIIWorld` — the data model (`Unit`/`Structure`/`House`/`Team`/`Map`/`Scenario`), object pools, static stat tables, the `GameState` aggregate (owns all mutable state: RNG, the two clocks, tick cursors), scenario `.INI` loading, our save/load, the original-save converter. Depends on Contracts + Formats.
    - `DuneIISimulation` — game logic + loop: native primitives (bit-exact), the per-type state machines (exact EMC transcription), the four-phase `tick()`, the two-clock + speed/pause model. Applies `Command`s, emits `FrameInfo` + `SoundEvent`s. Headless + deterministic. Depends on World + Contracts.
    - `DuneIIRenderer` — asset rendering services: `HouseRemap` (house color recolor, ported from OpenDUNE) + `IndexedImage` (indexed pixels + palette → `CGImage`), used by the render-test app. The `FrameInfo`-driven world renderer (SpriteKit) lands with the sim. Depends on Contracts + Formats; imports CoreGraphics.
    - `DuneIIInput` — `InputSource` protocol + `ScriptedInput` (Foundation) + the interactive `InputController` (selection/order state machine). The host wires native macOS `NSEvent`s to it. Depends on Contracts.
    - `DuneIIAudio` — `AudioSink` protocol + `NullAudio` (Foundation) + later Core Audio. Depends on Contracts.
    - `DuneIIExport` — asset writers (`PngWriter` via ImageIO/CoreGraphics, `WavWriter` via RIFF), used by `assetgen` to export decoded assets to PNG/WAV for verification. Depends on Formats. Offline tooling, not a runtime presentation leaf.
  - `Tools/` — command-line developer/build tools: `assetgen` (extract `Resources/` from the install + the `emc-disasm` subcommand).
  - `Apps/` — runnable end-products: `duneii` (the **native macOS** game client — SwiftUI map window + floating tool windows), `mapview`/`scenariolab` (single-window verification viewers), `rendertest` (asset inspector), `duneii-headless` (test/oracle driver), `rendercap` (headless render capture).
  - `Tests/` — one `<Subject>Tests` target per tested target (the `DuneII` prefix is dropped): `ContractsTests`, `FormatsTests`, `WorldTests`, `SimulationTests`; fixtures under `<Subject>Tests/Fixtures/`.
- `Repositories/OpenDUNE/` — the C reference and **oracle**. Source of truth for all game logic, save format, scripting, codecs, tables.
- `Repositories/dunepak/` — Rust PAK packer (PAK container reference).
- `Repositories/patched_107_unofficial/` — the original 1.07 install (read-only at runtime).
- `Resources/` — generated by `assetgen`. Committed. Do not hand-edit.

## Core principles

1. **Behavioral parity is the verification bar.** The engine is bit-identical to OpenDUNE wherever behavior is deterministic, and within OpenDUNE's own seed-to-seed spread wherever it is stochastic. We do **not** chase byte-exact tick/RNG-order parity against a savegame — that was the previous, failed approach. See `Architecture/ParityHarness.md`.
2. **Primitives bit-exact; behavior an exact EMC transcription.** Native primitives (movement, pathfinding, fire/damage, harvest, economy, both RNG generators, all stat tables) are ported bit-exactly from OpenDUNE. Per-type behavior is hand-written Swift state machines that are **exact logical transcriptions** of the disassembled EMC bytecode — same branches, conditions, thresholds, order of primitive calls — verified per-object by decision-trace equivalence.
3. **The simulation is the center; render/input/audio are mockable leaves.** They depend only on `DuneIIContracts`; they never depend on each other; the simulation depends on none of them.
4. **One `GameState`; no globals.** All mutable simulation state lives in one owned aggregate so sims can coexist, be snapshotted, and be tested repeatably.
5. **Determinism is mandatory.** Same scenario + seed + command stream ⇒ byte-identical run, every time.
6. **OpenDUNE is the oracle.** Ground every game-logic primitive in a specific `src/<file>.c:<lines>` and cite it in the Swift doc comment. If OpenDUNE is unclear or absent, surface the gap in History rather than inventing behavior.
7. **Trace logs are the parity stream.** Every simulation mutation gets a structured trace log (tracer label + tick + entity id + payload); these double as the semantic event trace the parity harness aligns against OpenDUNE.

## Conventions

- Swift 6.3.2, strict concurrency. No `@unchecked Sendable`, no `nonisolated(unsafe)`; use `Mutex` (`import Synchronization`) for synchronization. macOS 26 only (`@available(macOS 26.0, *)` where a newer API needs gating); the app host is native AppKit + SwiftUI (non-Catalyst).
- Follow the user's global Swift style guide at `~/Programming/_Scripts/Instructions/CLAUDE.CodeStyle.md`.
- File-format decoders live in `DuneIIFormats` under `Formats/<Name>/`, expose a single top-level type, and never read disk — they take `Data`. Filesystem integration lives above Formats.
- Codecs (`Format80`, `Format40`) are pure functions on `Data`, in `Codec/`.
- Every format/codec/primitive ships with Swift Testing coverage. Synthetic input preferred; real-data/oracle tests use the install and short-circuit when absent.
- Don't "improve" the simulation. Behavioral parity is the bar; exact EMC transcription is the requirement.

## Feature workflow

Steps 0, 1, 3, 4, 5, 6, 7 are mandatory. Tests are written **after** the feature (step 3).

**Every new feature requires a golden test.** Unit tests alone do not close a feature. For a gameplay/parity feature this means a **cross-engine scenario golden** (add a `Spec` to `ScenarioGoldenTests` + a `gen-scenario-goldens.sh` case + the matching oracle command in `parity.c`, regenerated and committed) — that is the verification bar (core principle 1). For a renderer feature it means a **render golden** (`RenderGoldenTests`). Only when no OpenDUNE oracle behaviour exists (a debug toggle, a pure presentation/UI seam) is a cross-engine golden impossible — there, the golden bar is a **flag-off / neutrality golden** (prove the existing scenario or render goldens stay byte-identical with the feature off) plus the unit coverage, and you must say so explicitly in the History entry.

0. Open `CurrentState.md`. Confirm the task matches the active task (or a queued next-up); if starting something new, record it there so a cold reader could resume.
1. Design on paper first — write/update the relevant doc under `Documentation/Formats/` (or `Algorithms/`, `Architecture/`) before code. Own-words + pointer to the reference C source.
2. Implement. No abstractions for hypothetical futures; no speculative generality. (The package seams in the plan are not speculative — they are required.)
3. Write tests for the new behavior. Synthetic preferred; add a real-data / oracle test when one can exercise the path.
4. Run the full suite — `cd Code && swift test`. Green before "done." Every previously-green test stays green.
5. Zero warnings after a clean rebuild — `swift package clean && swift build`. Every `warning:` is a failure; fix the root cause. Read the **full** build output (warnings surface early, during target scanning) — never a `tail`ed/grepped subset, or you will miss them.
6. Log the change — `Scripts/log-history.sh "<bullet>"` appends to today's `Documentation/History/YYYY-MM-DD.md` (creating the day file + its index link if new). One sentence, imperative, with file references.
7. Update `CurrentState.md` — move the finished item to "Recently completed" (with test count + History pointer), set the next "Active task" with its immediate next step, refresh "Test status." **And update `Documentation/Architecture/FeatureParity.md` whenever the change moves a gameplay feature's status** (✗ Missing / ⊘ Seam → ◐ Partial → ✅ Done, or a newly-ported behaviour): flip the row's status + evidence (`file:line` + test) and reconcile the "remaining gaps" summary. It is the living done/not-done table vs OpenDUNE; a parity-relevant change that doesn't touch it is incomplete. (Presentation-only seams — render/audio/menus — are out of its scope; skip those.)
8. If you learned something non-obvious, capture it as an insight under `Documentation/Insights/` and index it in `Insights/README.md`. Cross-link the code `file:line` and the test.

**Commit cadence.** Commit after every **2–3 blocks** are done (a block = one logical work-unit; see below), or after each phase. End commit messages with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer. Work happens on a feature branch off `main`.

**Chunking & check cadence (batched porting work).** When doing repetitive porting work in "blocks" (one logical work-unit, e.g. a stat table or primitive batch): work in **bigger chunks — bundle 2–3 blocks per commit**, not one tiny increment per commit. Relax the per-step checks of workflow steps 4–5 to match: a block's own new/changed tests must compile and pass every block (run the filtered subset, `swift test --filter <TypeName>` — the test struct name, not the `@Suite` display string); run the **full suite every 4–6 blocks** and a **clean build every 6–10 blocks**; always finish a push with a full suite + clean build before declaring done. These cadences are specific to this project.

## Periodic self-review

After each completed phase, **or** after every 32 commits (whichever comes first), reread `Documentation/History/` (at least the recent daily files — see its `README.md` index) and `Documentation/Insights/`. Extract any **recurring problems** or **important lessons** into new standing instructions (add them to this file under the relevant section) or new insights. **If nothing recurrent or important emerges, add nothing — do not manufacture instructions.** Track the last review point in `CurrentState.md` (record the commit hash); commits since = `git rev-list --count <hash>..HEAD`.

## What counts as "tested"

- Every `DecodeError` / throwing case has a test that throws it.
- Every branch on a format variant (compressed vs raw, modern vs legacy, continuation vs regular) has a test per branch.
- Every writer has a round-trip test.
- Every native primitive has a golden test against OpenDUNE-dumped values; every state machine has per-object decision-trace equivalence (Tier 2a) before integration.
- Every public function has at least one test on real or synthetic input.
- **Every feature has a golden test** (see Feature workflow step 3): a cross-engine scenario golden for gameplay/parity work, a render golden for renderer work, or — only when there is no OpenDUNE oracle behaviour (debug/UI/presentation seam) — a flag-off neutrality golden, called out as such in History.

If something genuinely can't be tested (rare — usually visual correctness), say so in the History entry and write a manual-verification checklist in the relevant doc. Don't skip silently. See `Architecture/Testing.md` and `Architecture/ParityHarness.md`.

## Running things

**Per-round checks go through `Scripts/`** — they encapsulate this repo's environment quirks (repo-local `TMPDIR`, `xcrun`, `--disable-sandbox`, the OpenDUNE shim + re-sign) and distill output to a concise "what's wrong" summary. Prefer them over re-typing raw commands:

```
Scripts/check.sh                    # incremental build + full test suite → concise BUILD/TESTS/VERDICT
Scripts/check.sh --full             # `swift package clean` first — the zero-warnings audit (workflow step 5)
Scripts/check.sh --filter <TypeName>   # build + only matching tests (fast inner loop). Matches the test struct/type NAME (e.g. `GameStateTests`), NOT the `@Suite("…")` display string — a display-name pattern runs 0 tests and falsely reads green. See insight `build-test-filter-suite-name`.
Scripts/log-history.sh "<bullet>"   # append a bullet to today's History/YYYY-MM-DD.md (workflow step 6; creates+indexes a new day)
Scripts/build-oracle.sh             # rebuild + re-sign the OpenDUNE parity oracle (run with sandbox disabled)
Scripts/gen-scenario-goldens.sh [--only <name>]   # regenerate the scenario goldens (one, with --only)
```

**Investigation helpers** (the source-reading / disasm probes that recur every porting slice):

```
Scripts/odfn.sh <FunctionName>          # print an OpenDUNE C function body + its file:line (the #1 re-typed command)
Scripts/emc.sh <unit|build|team> [N|--linear|all]   # disassemble an EMC script: one type N, the shared region (--linear), or all
Scripts/golden.sh <name> [both|units|structures]    # a scenario golden JSONL as a per-tick "what changed" timeline
```

**Maintain these scripts.** When you catch yourself repeating a manual step round after round — a new check, an output-parse, a probe you keep re-typing — fold it into `Scripts/check.sh` (or add a focused sibling script). The `Scripts/` directory is the single source of truth for "the regular actions each round"; keep it current instead of re-deriving the commands.

Raw commands (what the scripts wrap), if you need them directly:

```
cd Code
TMPDIR="$PWD/.build/tmp" xcrun swift build --disable-sandbox    # libraries + CLI executables
TMPDIR="$PWD/.build/tmp" xcrun swift test  --disable-sandbox    # full suite
swift run assetgen                # re-extract Resources/ from the install
swift run assetgen emc-disasm     # disassemble UNIT/BUILD/TEAM.EMC
```

## What not to do

- Do not chase byte-exact tick/RNG-order parity against a savegame — that is the failed approach. Behavioral parity (`ParityHarness.md`) is the bar.
- Do not "fix" a scenario-golden divergence by patching gameplay math before you have **trace-aligned the RNG stream**. Under a fixed seed + the same headless harness, a faithful transcription draws the *same number and order* of bytes as the oracle — so a divergence is a **real draw-count/order discrepancy, not unpinnable "spread."** Dump both engines' draws (oracle `--parity-random-trace=`/`--parity-lcg-trace=`, tagging `tick/idx/byte/ctx`), find the **first divergent draw by index**, and fix the missing/extra/reordered draw at that site — don't gate the golden around it, and don't assume idle/`wobble` rotation is inherently unmatchable. A `ctx=NULL` (or `t<team>`) draw the other engine doesn't make points at a **phase-level** draw (e.g. the `GameLoop_Team` cursor re-arm, a per-tick maintenance draw), not a per-unit one. (The `guard` tick-6 / `attack-rocket` tick-69 residuals were a *single* real bug — `GameLoop_Team` skipped its unconditional cursor draw when no `TEAM.EMC` was bridged — misdiagnosed for months as "wobble spread"; fixing it made both full 400-tick matches. See insight `sim-rng-stream-unpinned-wobble`.)
- Do not "improve," rebalance, or retime the simulation.
- Do not hand-edit `Resources/` — it is regenerated by `assetgen`.
- Do not add cross-platform abstractions. macOS 26 only.
- Do not clone OpenDUNE/dunepak into the build — they are external references under `Repositories/`.
- Do not couple the simulation to the renderer, input, or audio. They depend on `DuneIIContracts`; the simulation depends on none of them.
- Do not introduce global mutable simulation state — it belongs in `GameState`.
- Do not rewrite historical `History/*.md` entries. If one is wrong, add a dated correction.
- Do not hard-wrap Markdown paragraphs. One paragraph = one line; break only for lists, tables, fenced code, blockquotes.
