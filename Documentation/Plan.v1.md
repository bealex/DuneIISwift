# Dune II Swift — Core Engine Plan (v1)

**Date:** 2026-05-28. **Status:** architecture & principles locked; phased build not yet started. **Supersedes:** the original `Plans/01.Initial.md` direction (full remake + byte-exact tick parity), which produced the first attempt and was archived as unsuccessful.

This document is the authoritative result of the goals/principles/architecture discussion. A cold reader should be able to start the project from here. It captures *what we are building*, *the principles*, *the architecture (verified against OpenDUNE)*, *how we verify fidelity*, and *the phased build order*.

---

## 1. Goals & non-goals

We are building a **Swift core game engine for Dune II 1.07**, not a full reproduction of the shipped product.

**In scope**
- Game **logic** faithful to Dune II 1.07 (behavioral parity — see §5).
- **Rendering parity:** the game world is pixel-faithful in *content* — correct sprites, frames, tiles, palette, and world-space positions — but the original 320×200 logical image is **upscaled (nearest-neighbor) into a resizable, scalable window**, not pinned to a literal 320×200 framebuffer. The UI around the world is our own (§4.6).
- Data **loading and saving** (formats, scenarios, our own save format, plus a converter for original saves).
- Scenario **play**: a scenario runs, units/structures/economy/AI behave as in 1.07.
- **Extensibility** as a first-class concern: it must be possible to add new units, structures, and behaviors later without fighting the architecture.

**Out of scope (explicitly)**
- Menus, intros, cutscenes, mentat animations, the briefing/score screens.
- Reproducing the original's exact UI / HUD layout. We build our own **multi-window verification UI** instead (§4.6). The game *world* must be render-parity-faithful (§5); the surrounding UI need not match the original.
- Cross-platform abstractions. macOS 26 (Apple Silicon), Mac Catalyst, only.

**Non-negotiable tension, resolved:** "faithful to 1.07" and "extensible" conflict at the script-VM layer. We resolve it by targeting *behavioral* parity (not byte-exact), porting the deterministic primitives bit-exactly, and re-expressing behavior as hand-written state machines. See §3 and §5.

---

## 2. Guiding principles

1. **Behavioral parity, not byte-exact.** Success = the engine is bit-identical wherever behavior is deterministic, and statistically indistinguishable from "OpenDUNE run with a different seed" wherever behavior is stochastic. We do **not** chase tick-for-tick RNG-order parity against a specific savegame (that was the previous treadmill).
2. **Primitives faithful; behavior an exact transcription.** Native primitives (movement, pathfinding, fire/damage, harvest, economy math, both RNG generators, all stat tables) are ported **bit-exactly** from OpenDUNE. Per-unit/structure/team behavior is **hand-written Swift state machines that are exact logical transcriptions of the EMC scripts** — identical branches, conditions, thresholds, and order of primitive calls — derived by disassembling the original `UNIT.EMC`/`BUILD.EMC`/`TEAM.EMC` bytecode, not behavioral approximations. ("Behavioral parity" in principle 1 is the *verification bar* for integrated play; *exact EMC transcription* is the *implementation requirement* for each state machine — see §5.)
3. **Simulation is the center; presentation are mockable leaves.** Renderer, input, and audio depend only on a small Contracts layer; they never depend on each other; and the simulation depends on none of them. This is the seam OpenDUNE's `parity.c` already proves works.
4. **One owned GameState; no globals.** All mutable simulation state (object pools, map, RNG seeds, the two clocks, the per-subsystem tick cursors, build-availability flags) lives in a single owned aggregate so that two sims can coexist, state can be snapshotted, and tests are repeatable.
5. **Determinism is mandatory.** Same scenario + seed + command stream ⇒ byte-identical run, every time. This is the precondition for the sped-up test loop and for all parity checks.
6. **OpenDUNE is the oracle and source of truth.** When behavior is in question, OpenDUNE's C (under `Repositories/OpenDUNE/`) decides it. We generate test fixtures from a patched OpenDUNE.
7. **Process discipline (carried over, still valid):** design-on-paper first; tests after the feature but "done" requires green coverage; zero compiler warnings after a clean build; append a `History/` bullet per change; capture non-obvious findings as `Insights/`. **Every simulation mutation gets a structured trace log** — and those logs *are* the parity event stream (§5).

---

## 3. Locked decisions

| # | Decision | Choice | Consequence |
|---|---|---|---|
| 1 | Parity target | **Behavioral parity** | Validate against OpenDUNE as oracle; internal RNG order may differ; enables extensible state machines. |
| 2 | Original save compatibility | **Both + converter** | Support our own save format *and* read original `SAVE*.DAT` via a converter that maps the original's *semantic* state into our model. |
| 3 | Behavior implementation | **State machines = exact EMC transcription** | Per type, an exact logical port of the disassembled EMC bytecode, calling faithfully-ported primitives. No shipping EMC VM; an EMC disassembler is a dev tool, and per-object decision traces verify the transcription (§5, Tier 2a). |
| 4 | Renderer technology | **SpriteKit + Mac Catalyst** | But still behind a `Renderer` protocol with a `NullRenderer` for tests. |

**Save-converter nuance (important).** We do *not* resume the original's mid-opcode EMC VM state byte-for-byte. The converter reads the original save's semantic state (unit positions/types/HP/`actionID`, houses, credits, structures, map tiles, scenario) and instantiates *our* model + seeds *our* state machines into the equivalent state. **Accepted limitation:** a converted save continues *behaviorally faithfully* (a harvesting unit keeps harvesting) but not *bit-identically* to how OpenDUNE would have continued that exact save. This is consistent with the behavioral-parity choice.

---

## 4. Architecture

### 4.1 Package topology

One SwiftPM package, multiple targets (each can be built and tested separately; can be split into independent packages later). Names follow the existing `DuneII*` convention.

| Target | Kind | Role |
|---|---|---|
| `DuneIIFormats` | library | Pure `Data`→`Data` decoders/codecs: Format80/40, PAK, SHP, ICN/tiles, CPS, FNT, WSA, VOC, palette, INI, the SAVE IFF/FORM container, and the **EMC chunk reader + disassembler** (used as a dev tool to derive exact state-machine logic — see `emc-disasm`, §6 Phase 1; no runtime interpreter). Foundation-only. |
| `DuneIIWorld` | library | The model: `Object`/`Unit`/`Structure`/`House`/`Team`, `Map`/`Tile`, `Scenario`, the pools, the static stat tables (literal port of OpenDUNE `table/*info.c`), and the **`GameState`** aggregate owning all mutable state (RNG, the two clocks, tick cursors, `available` flags). Scenario `.INI` loading, our save/load, and the original-save converter. |
| `DuneIIContracts` | library | The seam: `FrameInfo` (sim→render), `Command` (input→sim), `SoundEvent` (sim→audio), plus shared IDs/enums. Self-contained value types. |
| `DuneIISimulation` | library | Logic **and** loop (combined — see §4.5). Native primitives, per-type state machines, the four-phase `tick()`, the two-clock + speed/pause model. Applies `Command`s; emits `FrameInfo` + `SoundEvent`s. Headless, deterministic, sped-up testable. |
| `DuneIIRenderer` | library | `Renderer` protocol + `NullRenderer` (tests) + `SpriteKitRenderer`. Renders pixel-faithful world *content* from `FrameInfo`, **upscaled (nearest-neighbor) into a resizable, scalable window** (not a fixed 320×200 framebuffer). Also exposes reusable **sprite/animation drawing services** (draw frame N of sprite S in house H's palette) used by the UI panels (§4.6) and the render-test app (§4.7). Depends on Contracts + Formats only. |
| `DuneIIInput` | library | `InputSource` protocol + `ScriptedInput` (mock) + `CatalystInput`. Depends on Contracts only. |
| `DuneIIAudio` | library | **Postponed.** `AudioSink` protocol + `NullAudio` now; Core Audio implementation later. The `SoundEvent` seam is built early so it slots in cleanly. |
| `duneii` | executable | Mac Catalyst app host. Hosts the **multi-window verification UI** (§4.6): map window (embeds `DuneIIRenderer`), inspector window, game-info window, build dialog. Wires Simulation + Renderer + Input + Audio. |
| `duneii-headless` | executable | Test/oracle driver: Simulation + NullRenderer + ScriptedInput + fast loop. Runs scenarios for parity checks. |
| `rendertest` | executable | **Renderer test app** (§4.7): browse and display any sprite at any frame/phase, play any animation, for any house palette. Verifies rendering parity in isolation. Depends on Formats + Renderer. |
| `assetgen` | executable | Extracts/regenerates `Resources/` from the install (kept — the engine needs the data). Also hosts the **`emc-disasm`** subcommand that disassembles `UNIT/BUILD/TEAM.EMC` to readable form for deriving exact state machines. |

### 4.2 Dependency rules

Dependencies point **downward only**. The four top subsystems never depend on each other; the simulation depends on none of the presentation packages.

```
 Hosts:  duneii (app)                          duneii-headless (tests/oracle)
            └──────── wire the pieces together ─────────┘
   ┌───────────┬───────────┬───────────┬────────────────────────────┐
   │ Renderer  │  Input    │  Audio    │  Simulation (logic + loop)  │
   │ FrameInfo │  Command  │ SoundEvent│  primitives + state machines│
   │  → pixels │  ← input  │  → audio  │  + 4-phase tick()           │
   └────┬──────┴─────┬─────┴─────┬─────┴──────────────┬─────────────┘
        │            │           │                    │
        └────────────┴─────┬─────┴────────────────────┘
                           ▼
                 ┌────────────────────┐
                 │ Contracts          │  FrameInfo · Command · SoundEvent · IDs
                 ├────────────────────┤
                 │ World (the model)  │  Unit/Structure/House/Team/Map/Scenario,
                 │  + GameState       │  pools, stat tables, RNG, clocks, cursors;
                 │  + Save/Load + conv │  scenario load; our + original saves
                 ├────────────────────┤
                 │ Formats / Codecs   │  PAK SHP WSA CPS ICN FNT VOC INI SAVE
                 └────────────────────┘  Format80/40 (pure Data→Data)
```

The Contracts seam is what lets packages be implemented separately: Renderer/Input/Audio can be built against Contracts (with recorded/stub `FrameInfo`) before Simulation internals exist, and Simulation can be built against Contracts with the `NullRenderer` before the real renderer exists.

### 4.3 What mirrors OpenDUNE vs. what departs

**Mirrors** (faithful to original structure): the four-phase tick order (Team → Unit → Structure → House); the object-pool model (fixed arrays + dense find-index) and encoded indices; the `Object`/`ObjectInfo` base split; seed-derived maps; the stat-table contents.

**Departs** (deliberately, for extensibility/testability): all global mutable state collapses into one owned `GameState`; render/input/audio become contract-bounded leaves; behavior becomes hand-written state machines instead of an EMC bytecode VM; the renderer is a pure function of a `FrameInfo` snapshot.

### 4.4 Key OpenDUNE constraints the design must honor

These are verified findings from reading `Repositories/OpenDUNE/`. They are requirements, not suggestions.

- **Canonical headless tick** = `{ timerGame++; timerGUI++; GameLoop_Team(); GameLoop_Unit(); GameLoop_Structure(); GameLoop_House(); }` (`parity.c:372-382`). Nothing presentation-related is required to advance the sim.
- **Two independently-gateable clocks.** `g_timerGame` drives gameplay; `g_timerGUI` drives presentation cadence. **Pause is a clock gate** (stop GAME, keep GUI), not a loop stop (`timer.c:378`).
- **Game speed is interval reshaping, not a clock multiplier** (`Tools_AdjustToGameSpeed`, `tools.c:20`). To run fast in tests, hold `gameSpeed` fixed and run ticks back-to-back; raising the speed setting *changes the simulation*.
- **Per-subsystem cadences** live in `static s_tick*` cursors inside the GameLoop functions: unit movement every 3 ticks, scripts every 5, AI teams a jittered 5–12, structure logic ~30, house economy 900. These **must become per-instance `GameState` fields**.
- **Stat tables are hardcoded C** (`table/*info.c`), not loaded from disk — port them as Swift `let`. Only EMC bytecode, scenario `.INI`, and saves are read at runtime. `ObjectInfo.available` is *mutable runtime state hiding in the "static" table* and must be hoisted into `GameState`.
- **Save format** is an IFF/FORM chunk container + a descriptor-driven field serializer; the **map is regenerated from a seed then patched** with only the differing tiles; the **RNG seed is not saved** by the original (we will save ours, to make round-trips deterministic).
- **Two RNG generators** must be ported bit-exactly: `Tools_Random_256` (custom LFSR-ish, `tools.c:268`) and a Borland LCG (`tools.c:327`). Bit-exact generators matter for distributional checks and semantic RNG pinning even though we drop byte-exact draw-order matching.
- **The render path currently mutates the sim.** `GUI_DrawScreen` calls `Explosion_Tick()`, `Animation_Tick()`, `Unit_Sort()` (`gui.c:4575`); explosion *damage* is already synchronous on the game clock (`Map_MakeExplosion`, `map.c:403`), but the *visual* explosion/animation VMs are GUI-clocked. We move all gameplay effects into the sim tick so the renderer is read-only over a snapshot.
- **Sound is fired inline** from sim logic (~10 sites in `unit.c`, plus structure/explosion/animation). The sim must instead emit `SoundEvent`s. Two cross-layer leaks to launder into data: `Sound_Output_Feedback` also sets viewport message text; voice attenuation reads the minimap position.
- **Input mutates the sim directly** (`GUI_Widget_Viewport_Click` → `Unit_SetAction`/`Structure_Place`). We translate input to `Command`s applied between ticks. OpenDUNE's built-in record/replay (`INPUT_MOUSE_MODE_PLAY`) is precedent for scripted input.
- **Behavior is script-driven and co-routined** (e.g. `Script_Unit_MoveToTarget` decrements the instruction pointer to re-run next tick, `unit.c:454`; pathfinding is opcode `0x0C` in `script/unit.c`). This is why logic and loop are one package and why state machines are *derived from* the EMC logic rather than invented.
- **Pin compatibility flags:** `g_dune2_enhanced = false` (the 1.07 path) everywhere; fixed `gameSpeed` for all comparisons.

### 4.5 Why logic and loop are combined

You suggested logic and loop might be separate packages ("or maybe even several"). We combine them into `DuneIISimulation` because OpenDUNE's logic and loop are tightly co-routined (a move opcode parks a unit's state on itself across ticks; the loop's cadence cursors are part of the behavior), and both are headless-testable together. A hard package wall buys friction with no testability benefit. If we later want hard separation, splitting out `DuneIILoop` is a mechanical refactor.

### 4.6 User interface (multi-window verification UI)

The UI is **our own**, built so a human can verify behavior — not a reproduction of the original HUD. It is a set of **independent, resizable, scalable tool windows** (pro-app style); the app shows/hides them, and they can be arranged freely. Every panel is a **Contracts-bound leaf** — it consumes `FrameInfo` to display and emits `Command`s to act, exactly like the renderer and input packages — so panels touch no simulation internals and are testable against recorded `FrameInfo`. The panels live in the `duneii` host (factorable into a `DuneIIUI` library if they grow).

The v1 window set:
- **Map window** — resizable, scalable view of the current map/world; embeds `DuneIIRenderer` (the world frame from `FrameInfo`). Handles selection and map orders, translated to `Command`s.
- **Inspector window** — info and available **actions** for the currently selected unit/building (type, HP, state, current order, stats); emits action `Command`s. The unit/building icon is drawn via `DuneIIRenderer`'s sprite services. **Building construction selection is a separate dialog** (the build menu: what a selected factory / construction yard can build, with costs and availability), issuing build `Command`s.
- **Game-info window** — global state: credits, power, spice, per-house unit/structure counts, tick/clock, game speed.
- **Extensible** — further tool windows ("and so on") follow the same `FrameInfo`-in / `Command`-out pattern.

This multi-window UI is also a **human-facing behavior-verification instrument** (the complement to the automated parity harness in §5): watch the map + inspector + game-info and confirm the engine plays like 1.07. Platform tech (Mac Catalyst `UIScene` multi-window vs AppKit windows) is an open item (§8).

### 4.7 Renderer test app (`rendertest`)

A standalone app for verifying **rendering parity in isolation**, independent of the simulation. It can: display **any sprite** (SHP/ICN) at **any frame/phase**; play **any animation** (WSA and in-game animation sequences); for **any house** (applying that house's palette remap); with frame step/scrub, palette inspection, and zoom/scale. It depends on `DuneIIFormats` (load assets) + `DuneIIRenderer` (draw them via the sprite/animation services). It is the asset-level rendering-parity tool: a rendered frame can be diffed pixel-exact against a reference PNG (from `assetgen` or an external dump). Built in Phase 4.

---

## 5. Behavioral parity verification

Behavioral parity is easy to achieve and hard to verify (the inverse of byte-exact). Once RNG draw-order may differ, two *faithful* sims drift apart in exact micro-state, so "diff the state" is the wrong instrument for the integrated sim. We use a graded approach: bit-exact where deterministic, rigorous-statistical where stochastic.

**Operational definition.** *Behavioral parity = bit-identical wherever behavior is deterministic, and within OpenDUNE's own seed-to-seed spread wherever it is stochastic.* The pass criterion for a fuzzy metric is not "close to one OpenDUNE run" but **"statistically indistinguishable from OpenDUNE run with a different seed."**

**Implementation fidelity vs. verification bar (do not conflate).** Two distinct requirements. *Implementation requirement:* each state machine is an **exact logical transcription** of its EMC script — identical branches, conditions, thresholds, and order of primitive calls (decision #3). *Verification bar for end-to-end play:* remains **behavioral**, because we deliberately do not reproduce the original's global tick scheduling or RNG draw-order. The implementation requirement is directly and exactly testable per object (Tier 2a); the behavioral bar covers the integrated, multi-object result where scheduling/RNG-order legitimately diverge.

### The verification pyramid (broad/cheap base → narrow/expensive top)

**Base — internal determinism (no oracle; precondition).** Our engine, same scenario + seed + command stream, run twice ⇒ byte-identical state. Catches accidental nondeterminism (Set/Dictionary iteration order, uninitialized reads, wall-clock leaks). Nothing above this means anything until it holds.

**Tier 1 — exact mechanics (golden tests on pure functions).** Most parity confidence lives here. Dump golden values from a patched OpenDUNE and assert bit-exact equality:
- Both RNG generators (seed 0 → first 10k draws match).
- Pathfinding routes for a corpus of (map, src, dst, movementType).
- Damage / build-cost / speed / rotation / tile-enter-score formulas; `Tools_AdjustToGameSpeed`; map-from-seed landscape (tile-for-tile); the stat tables.

**Tier 2 — exact integration (RNG-controlled micro-scenarios).** Hand-crafted tiny scenarios run in both engines with full state-diff, kept exactly comparable by either (a) choosing scenarios that consume **zero** RNG draws (verified by instrumenting a draw counter), or (b) **semantically pinning** the few draws they do hit (OpenDUNE's parity hooks already tag each draw with the owning unit/structure, so both engines get the same value for the same semantic decision regardless of stream position). Examples: harvester harvests one patch and docks; Quad crosses known terrain A→B; turret kills a stationary target; factory builds a Trike in T ticks and places it.

**Tier 2a — per-object decision-trace equivalence (the direct test of "matches EMC exactly").** For a given object in a given world state, single-step OpenDUNE's EMC interpreter and record the sequence of native-function calls (e.g. `FindBestTarget`, `CalculateRoute`, `Fire`) with their arguments and the resulting `ScriptEngine` variable changes; run our state machine on the equivalent state and assert it requests the **same primitives in the same order with the same arguments**. This is the operational check for decision #3's "exact EMC logic" requirement, independent of global scheduling, and it localizes a transcription error to the exact branch that diverged. It is the bridge between Tier 1 (pure functions) and Tier 2 (integrated micro-scenarios).

**Tier 3 — behavioral envelope (full scenarios; statistical + diagnostic).** For real `SCEN*.INI` levels where AI + RNG diverge trajectories:
- **Semantic event-trace alignment (primary instrument).** Both engines emit a high-level event log — `actionChanged{id,from,to,tick}`, `unitFired{id,target}`, `unitDied`, `structureBuilt{type}`, `harvesterDocked`, `creditsChanged{delta}`. Align the two streams (tolerant on tick) and report the **first divergent event**. This localizes behavioral bugs semantically instead of as field-level state diffs.
- **Metric checkpoints with OpenDUNE-derived tolerances.** Credits, per-house unit/structure counts, spice remaining, fog unveiled — compared as curves, with tolerance set to OpenDUNE's own **across-seed standard deviation** (measure the natural spread by running the oracle N times). Order-independent set checks for "what got built."
- **Distributional parity for inherently-random decisions.** Idle-wander direction, retreat rolls, AI target jitter, harvester credit jitter: run N seeds in both engines and compare the *distributions*, not individual values.

### Oracle mechanics

OpenDUNE under `Repositories/OpenDUNE/` is the **sole oracle** (it already carries parity hooks: `parity.c`, `Parity_DumpTick`, `Parity_DumpLandscape`, RNG/script trace hooks). We extend those to dump three fixture kinds **offline**: Tier-1 golden values, Tier-2/3 event traces + state snapshots, and Tier-3 N-seed batches. Fixtures are **committed**; CI tests our engine against the committed fixtures (no need to run OpenDUNE live in CI; regenerate when widening coverage). For Tier-2 exact fixtures, OpenDUNE runs in the same RNG-controlled regime (stub/pin).

*(Rejected alternative: keeping a faithful EMC VM in a test-only target as a second in-process oracle. It resurrects exactly the VM work we chose to avoid. Use OpenDUNE-the-binary only, unless we later decide the extra safety is worth it.)*

### This rides on the trace-log discipline we already follow

The standing rule — *every sim mutation gets a trace log with a tracer label* — **is** the Tier-3 event stream. Make those logs machine-parseable (tracer label + tick + entity id + structured payload) and the event-trace alignment harness falls out of logging we already do. The parity instrument and the debugging instrument become the same thing.

### Honest caveat

This is strictly weaker than byte-exact. The residual risk is a state-machine logic error that only manifests in an RNG-divergent branch never hit by a Tier-2 scenario; Tier-3 trace alignment + distributions are the net for that, but a net is not a proof. The trade is deliberate: we buy extensibility and escape the treadmill, and we make "plays the same" rigorous rather than perfect.

---

## 6. Build plan (phases)

Per-phase **done-bar** is what makes the phase complete. Parallelism is noted.

**Phase 0 — Foundations.** Rewrite `CLAUDE.md` for the new principles (engine-first, behavioral parity, state machines, package topology, mockable presentation, oracle testing). Write `Documentation/Architecture/Overview.md`, `Testing.md`, and `ParityHarness.md` (the §5 strategy). Recreate `CurrentState.md`. Scaffold all targets so the empty graph builds green. *Done:* `swift build` succeeds for every target; docs in place; CLAUDE.md reflects the new project.

**Phase 1 — `DuneIIFormats`.** Codecs first (Format80/40), then the decoders the engine needs (PAK, ICN/tiles, SHP, CPS, palette, FNT, WSA, VOC, INI, SAVE IFF/FORM reader). Build the **EMC chunk reader + `emc-disasm`** disassembler (an `assetgen` subcommand) that renders `UNIT/BUILD/TEAM.EMC` bytecode to readable form, so Phase 3 can transcribe exact state machines. Rebuild `assetgen` to regenerate `Resources/`. *Done:* round-trip tests for every writer; real-data tests against the install short-circuit when absent; `Resources/` regenerates byte-stable; `emc-disasm` produces readable listings for all three EMC files. *Independently implementable.*

**Phase 2 — `DuneIIWorld` + `DuneIIContracts`.** The model structs and pools; the stat-table port (`table/*info.c` → Swift `let`); the `GameState` aggregate; both RNGs bit-exact; encoded-index helpers; scenario `.INI` loading; our own save/load round-trip; the original-save converter. Define `FrameInfo`/`Command`/`SoundEvent`. *Done:* a scenario loads into a `GameState`; our save round-trips bit-exactly; the converter ingests an original `SAVE*.DAT`; Tier-1 golden tests for RNG + map-from-seed pass.

**Phase 3 — `DuneIISimulation`.** The heart. Each state machine is an **exact transcription of its disassembled EMC script** (from Phase 1's `emc-disasm`), verified by **per-object decision-trace equivalence** (Tier 2a) before integration. Order: loop + two-clock model + speed/pause → world-mutation primitives (movement, rotation, pathfinder, damage, fog/spice) → **one unit type end-to-end** (move/guard/attack) → harvester + refinery economy → structures + production → houses + teams + AI → projectiles + explosions. *Done per slice:* per-object decision traces match the EMC interpreter; Tier-2 deterministic scenario passes exact state-diff vs OpenDUNE; the whole sim runs headless + sped-up + deterministic; Tier-3 envelope holds on at least one full `SCEN*.INI`.

**Phases 4–5 — `DuneIIRenderer`, `rendertest`, and `DuneIIInput` (parallel with Phase 3 once Contracts is stable).** Renderer: `Renderer` protocol + `NullRenderer` + `SpriteKitRenderer` rendering **pixel-faithful world content from `FrameInfo`, upscaled (nearest-neighbor) into a resizable, scalable window**, plus reusable sprite/animation drawing services. Build the **`rendertest`** app (§4.7): browse any sprite frame/phase, play any animation, for any house. Input: `InputSource` + `ScriptedInput` (unlocks scripted Phase-3 test scenarios) + `CatalystInput`. *Done:* `rendertest` displays every sprite/animation for every house, and a sampled sprite frame diffs pixel-exact against a reference PNG; the renderer reproduces a recorded `FrameInfo` correctly; scripted input drives a headless scenario.

**Phase 6 — Hosts + multi-window UI.** `duneii` (Catalyst app) hosts the **multi-window verification UI** (§4.6): map window, inspector window, game-info window, and the build dialog — each a Contracts-bound panel consuming `FrameInfo` and emitting `Command`s. `duneii-headless` (oracle/test driver) wires the headless path. *Done:* a scenario is playable and observable across the windows (a human can verify it plays like 1.07); the headless driver runs the parity corpus.

**Phase 7 — `DuneIIAudio` (postponed).** `AudioSink` + `NullAudio` exists from Phase 0; add a Core Audio implementation consuming `SoundEvent`s when prioritized.

---

## 7. Deliberate divergences (catalog)

Documented so they are never mistaken for bugs:
- **RNG draw-order differs** from OpenDUNE by design (the basis of behavioral parity).
- **Off-screen script throttle absent.** OpenDUNE runs off-screen units at 3 opcodes vs 52 on-screen; our state machines have no opcode budget, so this vanishes. It is a perf hack, not intended gameplay; we assert at the metric level that it does not move outcomes.
- **Converted original saves** continue behaviorally-faithfully, not bit-identically.
- **Compatibility flags pinned:** `g_dune2_enhanced = false`; fixed `gameSpeed` for all comparisons.

---

## 8. Open items / immediate next steps

1. Execute **Phase 0** (rewrite `CLAUDE.md`, write the architecture/testing/parity docs, recreate `CurrentState.md`, scaffold the target graph).
2. Confirm the **package names** and the single-package-multi-target layout (vs. truly separate packages) before scaffolding.
3. Decide whether `assetgen` + committed `Resources/` are regenerated fresh in Phase 1 or carried forward.
4. Stand up the **OpenDUNE oracle tooling** (extend the existing parity hooks to dump Tier-1/2/3 fixtures, including per-object decision traces for Tier 2a) early in Phase 1–2 so fixtures exist before Phase 3 needs them.
5. Decide the **multi-window UI tech** (Mac Catalyst `UIScene` multi-window vs AppKit windows) and whether the UI panels become a `DuneIIUI` library or stay in the `duneii` host.
6. Confirm the **v1 window set** (map, inspector, game-info, build dialog) and which additional tool windows are wanted.

---

## 9. Phase 3 native-primitive order (smallest → largest, dependency-aware)

The implementation order for the Phase-3 native primitives. Built bottom-up: a primitive is only started once everything it depends on is done. **Every primitive must match its OpenDUNE function by result/effect** — golden-tested against the oracle where it is a pure function of its inputs, and verified by `GameState` state-diff / Tier-2a decision trace where it mutates state. `✓` = done; paths under `src/`.

**Tier 0 — pure scalar/geometry (done).** Both RNGs ✓; `Tile_PackTile`/`Tile_UnpackTile`/`PackXY`/`GetPackedX/Y` ✓; `Tile_GetDistance`/`DistancePacked`/`DistanceRoundedUp` ✓; `Tile_GetDirection`/`DirectionPacked` ✓; `Tile_AddTileDiff` ✓; `Orientation_Orientation256ToOrientation8`/`16` ✓; `Tools_AdjustToGameSpeed` ✓; `Tools_Index_GetType`/`Decode`/`Encode`/`IsValid`/`Get*` ✓.

**Tier A — pure tile helpers (no `GameState`; golden-tested). ✓ done.**
1. `Tile_Center` (`tile.c:70`) — none. ✓
2. `Tile_IsOutOfMap` (`tile.h:119`) — none. ✓
3. `_stepX`/`_stepY` step tables + `Tile_MoveByDirection` (`tile.c:230,276`) — step tables. ✓
4. `Tile_MoveByRandom` (`tile.c`) — step tables + `Random256` ✓. Golden-tested per-seed (our RNG is bit-exact, so an isolated call matches the oracle byte-for-byte). ✓

**Tier B — unit orientation / rotation (mutate a `Unit`; `DuneIISimulation.UnitLogic`).**
5. `Unit_SetOrientation` (`unit.c:1671`) — `UnitInfo.turningSpeed` ✓. **done.**
7. `Unit_Rotate` (`unit.c:65`) — `Orientation_256To8/16` ✓. **done** (orientation state effect; the trailing `Unit_UpdateMap(2,…)` is render dirty-marking + visibility counts that don't change the unit's own state — deferred with 6). Drives the loop's `tickRotation`.

**Tier C — speed.**
8. `Unit_SetSpeed` (`unit.c:1902`) — `UnitInfo` ✓. **done.**

> **Dependency correction (found during implementation).** `Unit_UpdateMap` (old 6), `Unit_Move` (old 9), and `Unit_MovementTick` (old 10) are **not** smaller than the map cluster: they need `Map_GetLandscapeType` / `Map_UpdateAround` / fog-unveil (Tier D), `Unit_Remove` (Tier F), and `Unit_Damage` (Tier E). They are **resequenced to after Tier D** (and the lifecycle/combat bits they touch), so the build stays strictly bottom-up:
> - **D′1.** `Unit_UpdateMap` — needs Tier D map + fog + `Unit_HouseUnitCount`.
> - **D′2.** `Unit_Move` (`unit.c:1286`) — needs `Tile_MoveByDirection` ✓, `Unit_UpdateMap` (D′1), `Map_GetLandscapeType`/unveil (Tier D), `Unit_Remove` (Tier F), `Unit_Damage` (Tier E).
> - **D′3.** `Unit_MovementTick` (`unit.c:98`) — needs `Unit_Move` (D′2). Drives the loop's `tickMovement`.

**Tier D — map state.** (`DuneIISimulation.MapPrimitives`.)
12. `Map_IsValidPosition` (`map.c`) — `g_mapInfos` (`MapInfo.scales` ✓) + `Scenario.mapScale`. **done** (golden).

> **Prerequisite found (during implementation), now satisfied.** The rest of Tier D needs the **runtime tile-id bases** (`TileIDs`: `veiled`/`landscape`/`wall`/`bloom`/`builtSlab`) that `Sprites_Init` (`sprites.c:274`) derives from `ICON.MAP` — **done** (`DuneIIWorld.TileIDs`, `GameState.tileIDs`), as is map-from-seed (`createLandscape`) and scenario `.INI` loading. With those:
> - 11. `Map_GetLandscapeType` (`map.c`) — **done** (`MapPrimitives.landscapeType` + `_landscapeSpriteMap`; golden vs the oracle over every generated tile, `LandscapeTypeTests`). The structure case is the tile's `hasStructure` flag.
> - 13. `Map_IsPositionUnveiled` (`map.c`) — **done** (`MapPrimitives.isPositionUnveiled` + `tileIsUnveiled` = `Tile_IsUnveiled`; `UnveilTests`). `Map_UnveilTile` — still pending: needs `Unit_HouseUnitCount`, neighbour-unveil, render dirty-marking.
> - 14. `Map_ChangeSpiceAmount` — **done** (`MapPrimitives.changeSpiceAmount` + the private `fixupSpiceEdges` = `Map_FixupSpiceEdges`; golden, `SpiceTests`). `Map_SearchSpice` — **done** (`MapPrimitives.searchSpice`; golden, `SearchSpiceTests`), unblocked by the new `GameState.unitGetByPackedTile` (`Unit_Get_ByPackedTile`) + `unitIsTypeOnMap` pool queries.
> - 15. `Map_UpdateAround` / `Map_MakeExplosion` — larger; explosions/animation tables (also the render seam).

**Tier E — combat / scoring.** (`DuneIISimulation`.)
- `House_AreAllied` (`house.c`) — `g_playerHouseID` (`GameState.playerHouseID`). **done** (golden, `HousePrimitives`). Used by 16/18.
- 16. `Unit_GetTileEnterScore` (`unit.c:2335`) — **done** (`UnitPrimitives.tileEnterScore` + `isValidMovementIntoStructure` in `DefaultUnitPrimitives`, composing `Map_IsValidPosition`/`Map_GetLandscapeType`/`House_AreAllied`; + the World pool query `GameState.structureGetByPackedTile` = `Structure_Get_ByPackedTile`). Golden over the landscape path (`tileenterscore-golden.jsonl`, `g_dune2_enhanced` pinned false in `Parity_DumpGolden`), decision-trace over the occupant/structure branches (`UnitMovementDecisionTests`). The pathfinder (#21) prerequisite.
- 17. `Unit_Deviate` (`unit.c`) — `HouseInfo` ✓, `Random256` ✓; but calls `Unit_SetAction` + `Unit_UntargetMe` (**Tier F**) → blocked.
- 18. `Unit_Damage` (`unit.c:1530`) — `Unit_RemovePlayer`/`Unit_Remove` (**Tier F**), `Map_FillCircleWithSpice` (Tier D), explosions (15) → blocked.

**Net:** the scenario/map/sprite-init layer is now done, so Tier D (`Map_GetLandscapeType`/fog/spice) and the read-only part of Tier E (`Unit_GetTileEnterScore` #16) are done. What remains in Tier E (#17 `Unit_Deviate`, #18 `Unit_Damage`) is gated on Tier-F lifecycle (`Unit_Remove`/`Unit_SetAction`/`Unit_UntargetMe`), as are the resequenced `Unit_UpdateMap`/`Unit_Move`/`Unit_MovementTick` (D′1–D′3). **Recommended next: Tier F lifecycle — `Unit_SetAction`/`Unit_UntargetMe`/`Unit_Remove` — which unblocks the rest of E and the movement cluster, then the pathfinder (#21, which already has its #16 cost function).**

**Tier F — lifecycle / orchestration / pathfinding (largest).**
- **Pool `_Free` (done).** `GameState.unitFree`/`structureFree`/`teamFree` (`pool/*.c`) + `ScriptEngine.reset` (`Script_Reset`) — flags-clear, find-array compaction, house-count decrement; `GameStateTests`.
- **Reference-clearing cluster (done).** `GameState.unitUntargetMe` (`unit.c`) + its helpers `objectScriptVariable4Set`/`Clear` (`object.c`), `structureSetState`/`structureGetLinkedUnit` (`structure.c`), `unitRemoveFromTeam` (`unit.c`) — all World-layer pool/object bookkeeping; `GameStateLifecycleTests`.
19. `Unit_SetDestination` / `Unit_SetAction` (`unit.c:497`) / `Unit_Hide` — pools ✓, Tiers B–D; **`Unit_SetAction` is gated on the EMC script VM** (`Script_Reset` ✓ but `Script_Load`/`Script_LoadAsSubroutine` not yet ported).
20. `Unit_Remove` (`unit.c`) — **done** (`GameState.unitRemove`). Brought in `unitUpdateMap` (headless state subset of `Unit_UpdateMap` — visibility counts + tile occupancy; air-redraw/render-dirty/fog-radius are seams), `unitRemoveFromTile`, `unitHouseUnitCountAdd`/`Remove`. Two seams remain in `unitHouseUnitCountAdd`: the player-alert block (audio/GUI/`selectionType`) and the ambush→`Unit_SetAction(HUNT)` reaction (needs the EMC VM, #19); `Unit_Select` deselect is a render seam.
21. pathfinder: `Script_Unit_Pathfinder` + `_Connect` + `_Smoothen` (`script/unit.c:1183,1117,1012`) — `Unit_GetTileEnterScore` (16) ✓, `Tile_*` ✓.

Structure/House/Team primitives follow the same bottom-up discipline once the unit cluster is in; they are sequenced when their game-loop slices are ported.

---

## Appendix — OpenDUNE porting reference (file:line)

Compact map for implementers. Paths under `Repositories/OpenDUNE/src/`.

- **Tick / loop:** `parity.c:372-382` (headless tick); `GameLoop_Team` `team.c:22`; `GameLoop_Unit` `unit.c:123`; `GameLoop_Structure` `structure.c:53`; `GameLoop_House` `house.c:51`; main loop `opendune.c:906-1147`.
- **Timing:** `Timer_Tick` 60 Hz `timer.c:361`; `Tools_AdjustToGameSpeed` `tools.c:20`; pause gate `timer.c:378`.
- **Script VM (reference for deriving state machines):** `Script_Run` `script.c:323-598`; loader `script.c:650-729`; structs `script.h:40-65`; native tables `script.c:42-159`; per-tick ticking `unit.c:289-306`, `structure.c:325-344`, `team.c:37-62`; action→reload `Unit_SetAction` `unit.c:497-531`; co-routine pattern `unit.c:454`.
- **Data model:** `object.h:40-50`, `unit.h:141-170`, `structure.h:89-100`, `house.h:76-98`, `team.h:34-48`; pools `pool/*.c`; stat tables `table/unitinfo.c`, `table/structureinfo.c`, `table/houseinfo.c`, `table/landscapeinfo.c`, `table/actioninfo.c`.
- **Persistence:** `save.c`, `load.c`, `saveload/*` (descriptor tables); scenario `scenario.c`, `ini.c`; encoded indices + RNG `tools.c` (`Tools_Random_256` `:268`, LCG `:327`); load lifecycle `Game_Init`/`Game_Prepare` `opendune.c:1393-1552`.
- **Native logic:** `Unit_Move` `unit.c:1286`, `Unit_MovementTick` `unit.c:98`, `Unit_Rotate` `unit.c:65`, `Unit_Damage` `unit.c:1530`, `Unit_GetTileEnterScore` `unit.c:2335`; pathfinder `script/unit.c:1183` (`_Connect` `:1117`, `_Smoothen` `:1012`); map `map.c` (`g_map`, `Map_MakeExplosion` `:403`); structures `structure.c` (`Structure_BuildObject` `:1442`).
- **Presentation seams:** framebuffer `gfx.c`; driver contract `video/video.h` (8 fns); world draw `GUI_DrawScreen` `gui.c:4559`, `viewport.c`; input `input.c`, `mouse.c` (record/replay `INPUT_MOUSE_MODE_PLAY`); audio `audio/sound.c`, `audio/dsp.h` + null driver `dsp_none.c`.
- **Parity harness:** `parity.c` (`Parity_Run` `:291`, `Parity_DumpTick` `:278`, `Parity_DumpLandscape`); RNG/script trace hooks in `tools.c` and `script.c`.
