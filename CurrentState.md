# Current State

**Branch:** `rebuild/core-engine` (off `main`). **Plan of record:** `Documentation/Plan.v1.md`. **Architecture:** `Documentation/Architecture/Overview.md`.

## Active task

**Phase 2 — `DuneIIWorld` + `DuneIIContracts`.** Phase 1 (the format/codec/EMC layer) is complete and tested on real install data. Immediate next step: define the shared seam value types in `DuneIIContracts` (`HouseID`/`UnitType`/`StructureType` enums, tile/position types) and begin `DuneIIWorld` — the POD model + the static stat-table port from OpenDUNE `src/table/*info.c` (start with `houseInfo`/`landscapeInfo`, then unit/structure info). Then `GameState` (owning both bit-exact RNGs `Tools_Random_256` + Borland LCG, the two clocks, the per-subsystem tick cursors), scenario `.INI` loading via `Ini`, our save/load via `Iff`, and the original-save converter. Use `assetgen emc-disasm` output as the behavioral reference where scripts inform data.

## Next up (queue)

- **Render inspector — assembled buildings** (optional refinement): units, buildings, and terrain are now grouped (the "Units"/"Buildings"/"Terrain" categories). Buildings are shown as their individual 16×16 ICON.ICN tiles. Assembling a building's tiles into its full multi-tile shape (and the structure tile-cycle animation) needs `structureInfo.layout` + `g_table_animation_structure` — do if wanted. (`SpriteCatalog`/`IconMap` grouping is renderer/format-side metadata to reconcile with `DuneIIWorld`'s eventual `unitInfo`/`structureInfo` port — insight `sprite-global-indices`.)
- **Phase 3 — `DuneIISimulation`.** Loop + clocks → primitives → one unit type end-to-end → economy → structures → houses/teams/AI → projectiles/explosions. State machines = exact EMC transcription, verified by Tier-2a decision traces.
- **Phases 4–5 — `DuneIIRenderer` + `rendertest` + `DuneIIInput`.**
- **Phase 6 — hosts + multi-window UI.**
- **Phase 7 — `DuneIIAudio`.**

## Recently completed

- Reset to a core-engine rebuild; wrote `Documentation/Plan.v1.md` (commit `9b8ee1f`). See History 2026-05.
- Phase 0 docs: CLAUDE.md rewrite + Architecture/{Overview,Testing,ParityHarness}.md + this file + History/Insights (commit `68301f4`).
- Phase 0 scaffold: `Code` SwiftPM graph — 7 libraries + `assetgen` + `duneii-headless` + per-module CLAUDE.md. Clean build, zero warnings, 4 scaffold tests green.
- Phase 1: Format80 (LCW) decode ported from OpenDUNE `src/codec/format80.c` + `Documentation/Formats/Format80.md` + 11 decode tests. See History 2026-05; insight `codec-format80-overlap.md`.
- Phase 1 (rest): Format40, PAK, Palette, IFF, SHP, CPS, ICN, WSA, FNT, VOC, INI, EMC ports + `emc-disasm`; per-format docs; real-data decodes from install PAKs; insights. Fixed the Phase-0 SwiftPM unhandled-files warnings (per-module CLAUDE.md excluded). See History 2026-05.
- Phase 1 (asset export): `DuneIIExport` (`PngWriter`/`WavWriter`) + `assetgen extract` → PNG/WAV/EMC-listing output; verified on the real install (350 assets, 0 failures; CPS 320×200, valid WAVs). Closes the Phase-1 asset-regeneration deferral. 60 tests green.
- Renderer + render-test app (Phase 4 pulled forward): `DuneIIRenderer` asset services (`HouseRemap`, `IndexedImage`) + `rendertest` SwiftUI inspector (`swift run rendertest`) — asset hierarchy, animated playback, house recolor, 1×–16× scale, VOC playback. Pixel logic test-verified + OpenDUNE-faithful; on-screen look to be confirmed by running it. 64 tests green.
- rendertest refinements: frame animation off by default (Play toggle + frame stepper; thumbnails show index + size); `PaletteAnimator` palette cycling (wind-trap index 223 etc.) with a live "Palette cycling" toggle; colorize-on-display so house + palette changes apply live. 65 tests green.
- rendertest logical sprite grouping: `SpriteCatalog` (DuneIIRenderer) splits the unit SHPs (UNITS/UNITS1/UNITS2) into per-unit groups (directional vs animation), surfaced as a "Units" category; directional groups offer a Facing stepper (no auto-animate), animation groups a Play. Scale picker now also scales the grid thumbnails. 66 tests green.
- rendertest building/terrain grouping: `IconMap` decoder (DuneIIFormats) + "Buildings"/"Terrain" categories — each ICON.MAP icon group lists its ICON.ICN tiles (subitems) with house remap + palette cycling. 68 tests green.
- rendertest MENSHPM palette fix: mentat face sprites colored by their `MENTAT<house>.CPS` palette (not IBM.PAL) via `AssetLibrary.cpsPalette` + `AssetDetailView.mentatPalette` (OpenDUNE `gui/mentat.c:494`). Build clean. Insight `render-contextual-palette`.

## Test status

`cd Code && swift test`: **68 tests, all green** (format/codec/EMC/IconMap layer + PNG/WAV export + renderer house-remap/image/palette-cycling/sprite-catalog, synthetic + real-data). Clean build (`swift package clean && swift build`): zero warnings (full output audited).

## Open decisions (from Plan.v1.md §8)

1. Package layout — proceeding with `Code` single-package multi-target as planned (swift-tools 6.3, macOS 26). Adjust if desired.
2. `assetgen` + `Resources/` regenerate fresh in Phase 1 (planned).
3. OpenDUNE oracle tooling stood up in Phase 1–2.
4. Multi-window UI tech (Catalyst `UIScene` vs AppKit) — decide at Phase 6.

## Self-review tracker

Baseline tag: `selfreview-phase1` (set at the Phase 1 commit). Commits since = `git rev-list --count selfreview-phase1..HEAD`. Trigger: each completed phase, or every 32 commits. See CLAUDE.md → "Periodic self-review." Phase 0 review: nothing recurrent (first phase). Phase 1 review (done): recurring issue = build warnings hidden by `tail`; strengthened CLAUDE.md step 5 (read full build output) and captured insight `build-swiftpm-unhandled-files`.
