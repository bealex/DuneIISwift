# Current State

**Branch:** `rebuild/core-engine` (off `main`). **Plan of record:** `Documentation/Plan.v1.md`. **Architecture:** `Documentation/Architecture/Overview.md`.

## Active task

**Phase 2 — `DuneIIWorld` + `DuneIIContracts`.** Phase 1 (the format/codec/EMC layer) is complete and tested on real install data. Immediate next step: define the shared seam value types in `DuneIIContracts` (`HouseID`/`UnitType`/`StructureType` enums, tile/position types) and begin `DuneIIWorld` — the POD model + the static stat-table port from OpenDUNE `src/table/*info.c` (start with `houseInfo`/`landscapeInfo`, then unit/structure info). Then `GameState` (owning both bit-exact RNGs `Tools_Random_256` + Borland LCG, the two clocks, the per-subsystem tick cursors), scenario `.INI` loading via `Ini`, our save/load via `Iff`, and the original-save converter. Use `assetgen emc-disasm` output as the behavioral reference where scripts inform data.

## Next up (queue)

- **Deferred from Phase 1** — full `Resources/` image/audio regeneration (PNG/WAV writers via ImageIO). Not blocking: it is the writer layer, and `Resources/` is committed and not needed for Phases 2–3.
- **Phase 3 — `DuneIISimulation`.** Loop + clocks → primitives → one unit type end-to-end → economy → structures → houses/teams/AI → projectiles/explosions. State machines = exact EMC transcription, verified by Tier-2a decision traces.
- **Phases 4–5 — `DuneIIRenderer` + `rendertest` + `DuneIIInput`.**
- **Phase 6 — hosts + multi-window UI.**
- **Phase 7 — `DuneIIAudio`.**

## Recently completed

- Reset to a core-engine rebuild; wrote `Documentation/Plan.v1.md` (commit `9b8ee1f`). See History 2026-05.
- Phase 0 docs: CLAUDE.md rewrite + Architecture/{Overview,Testing,ParityHarness}.md + this file + History/Insights (commit `68301f4`).
- Phase 0 scaffold: `Code` SwiftPM graph — 7 libraries + `assetgen` + `duneii-headless` + per-module CLAUDE.md. Clean build, zero warnings, 4 scaffold tests green.
- Phase 1: Format80 (LCW) decode ported from OpenDUNE `src/codec/format80.c` + `Documentation/Formats/Format80.md` + 11 decode tests. See History 2026-05; insight `codec-format80-overlap.md`.
- Phase 1 (rest): Format40, PAK, Palette, IFF, SHP, CPS, ICN, WSA, FNT, VOC, INI, EMC ports + `emc-disasm`; per-format docs; 57 tests green incl. real-data decodes from install PAKs; 3 insights. Fixed the Phase-0 SwiftPM unhandled-files warnings (per-module CLAUDE.md excluded). See History 2026-05.

## Test status

`cd Code && swift test`: **57 tests, all green** (the format/codec/EMC layer, synthetic + real-data). Clean build (`swift package clean && swift build`): zero warnings (full output audited).

## Open decisions (from Plan.v1.md §8)

1. Package layout — proceeding with `Code` single-package multi-target as planned (swift-tools 6.3, macOS 26). Adjust if desired.
2. `assetgen` + `Resources/` regenerate fresh in Phase 1 (planned).
3. OpenDUNE oracle tooling stood up in Phase 1–2.
4. Multi-window UI tech (Catalyst `UIScene` vs AppKit) — decide at Phase 6.

## Self-review tracker

Baseline tag: `selfreview-phase1` (set at the Phase 1 commit). Commits since = `git rev-list --count selfreview-phase1..HEAD`. Trigger: each completed phase, or every 32 commits. See CLAUDE.md → "Periodic self-review." Phase 0 review: nothing recurrent (first phase). Phase 1 review (done): recurring issue = build warnings hidden by `tail`; strengthened CLAUDE.md step 5 (read full build output) and captured insight `build-swiftpm-unhandled-files`.
