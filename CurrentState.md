# Current State

**Branch:** `rebuild/core-engine` (off `main`). **Plan of record:** `Documentation/Plan.v1.md`. **Architecture:** `Documentation/Architecture/Overview.md`.

## Active task

**Phase 0 — Foundations.** Docs done (CLAUDE.md rewrite, Architecture/{Overview,Testing,ParityHarness}.md, this file, History, Insights README). Immediate next step: scaffold the `Code/Core` SwiftPM target graph (7 libraries + `assetgen` + `duneii-headless`) so `swift build` and `swift test` are green, then commit.

## Next up (queue)

- **Phase 1 — `DuneIIFormats`.** Codecs first (Format80, then Format40), then PAK, ICN/tiles, SHP, CPS, palette, FNT, WSA, VOC, INI, the SAVE IFF/FORM reader. Build `emc-disasm`. Rebuild `assetgen` to regenerate `Resources/`. Design-on-paper each format under `Documentation/Formats/` first.
- **Phase 2 — `DuneIIWorld` + `DuneIIContracts`.** Model, stat-table port, `GameState`, both RNGs bit-exact, scenario `.INI` load, our save round-trip, original-save converter. Define `FrameInfo`/`Command`/`SoundEvent`.
- **Phase 3 — `DuneIISimulation`.** Loop + clocks → primitives → one unit type end-to-end → economy → structures → houses/teams/AI → projectiles/explosions. State machines = exact EMC transcription, verified by Tier-2a decision traces.
- **Phases 4–5 — `DuneIIRenderer` + `rendertest` + `DuneIIInput`.**
- **Phase 6 — hosts + multi-window UI.**
- **Phase 7 — `DuneIIAudio`.**

## Recently completed

- Reset to a core-engine rebuild; wrote `Documentation/Plan.v1.md` (commit `9b8ee1f`). See History 2026-05.
- Phase 0 docs (CLAUDE.md rewrite + Architecture docs + this file). See History 2026-05.

## Test status

No targets yet (scaffold pending). After scaffold: `cd Code/Core && swift test`.

## Open decisions (from Plan.v1.md §8)

1. Package names / single-package-multi-target layout — proceeding with `Code/Core` multi-target as planned; adjust if desired.
2. `assetgen` + `Resources/` regenerate fresh in Phase 1 (planned).
3. OpenDUNE oracle tooling stood up in Phase 1–2.
4. Multi-window UI tech (Catalyst `UIScene` vs AppKit) — decide at Phase 6.

## Self-review tracker

Last self-review baseline: set at the Phase 0 scaffold commit (record hash here). Trigger: each completed phase, or every 32 commits (`git rev-list --count <hash>..HEAD`). See CLAUDE.md → "Periodic self-review."
