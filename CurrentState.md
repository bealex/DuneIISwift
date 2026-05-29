# Current State

**Branch:** `main`. **Plan of record:** `Documentation/Plan.v1.md`. **Architecture:** `Documentation/Architecture/Overview.md`.

## Active task

**Phase 2/3 — port the native functions the EMC scripts call, golden-tested against OpenDUNE, then transcribe the EMC files.** Approach + status in `Documentation/Architecture/FunctionParityHarness.md` (the 3-step plan: port primitives → match-test each vs OpenDUNE → port EMC). The OpenDUNE oracle builds headlessly here and has a `--parity-golden` function-dump mode.

**Done so far (Tier-0 primitives, all golden-verified):** both RNGs (`DuneIIWorld/Rng/`); tile geometry + orientation (`DuneIIWorld/Tile/` — `Tile32` pack/unpack/distance/direction, `Orientation`); `Tools_AdjustToGameSpeed` + `Tools_Index_GetType`/`Decode` (`DuneIIWorld/Tools/`). Per-category fixtures under `WorldTests/Fixtures/` (`rng-`, `tile-`, `gamespeed-`, `index-golden.jsonl`) via `opendune --parity-golden=<dir>` + the shared `GoldenFixture` loader. Tier-0 pure primitives are essentially complete.

**World model started — stat tables (golden-verified):** `HouseID` (Contracts) + `HouseInfo`; `LandscapeType`/`MovementType` + `LandscapeInfo`; `ActionType`/`SelectionType` + `ActionInfo`, all in `DuneIIWorld/Stats/`.

**Immediate next step:** the big stat tables — `ObjectInfo` + `UnitInfo` (`unitinfo.c`, ~27 units, incl. the 13-bit `ObjectInfo.flags` bitfield) and `StructureInfo` (`structureinfo.c`), with the `UnitType`/`StructureType` seam enums. Then the `Unit`/`Structure`/`House`/`Team`/`Map` PODs, object pools (fixed arrays + find-index), and `GameState` (owns both RNGs, the two clocks, tick cursors). That unlocks the deferred pool-dependent primitives (`Tools_Index_Encode`/`IsValid`/`Get*`) and the World-dependent script functions; the EMC transcription follows, verified by Tier-2a decision traces. (Reconcile `DuneIIRenderer.StructureCatalog`/`SpriteCatalog` against the real `unitInfo`/`structureInfo` once ported.)

## Next up (queue)

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
- rendertest assembled buildings: `StructureCatalog` (DuneIIRenderer) maps structure icon groups → `(w,h)` tile layout (OpenDUNE `structureinfo.c`); the `.iconGroup` decode assembles a building's tiles (consecutive `w*h`-tile states, row-major per `Structure_UpdateMap`) into whole-building frames. Buildings category now shows whole buildings, not separate tiles. 69 tests green. Insight `render-structure-layout`.
- rendertest palette-cycling correctness fix: cycling (`GUI_PaletteAnimate`) now applies **only** to IBM.PAL-rendered content — `AssetDetailView.decode` gates `paletteAnimatable = !rawFrames.isEmpty && displayPalette == nil`. Assembled structures default to the built state (2) so the windtrap power light (index 223, present only in built states) actually pulses. Insight `render-palette-animation` (extended).
- rendertest context palettes: discovered the mentat CPS/SHP and the intro/finale WSAs **embed no palette** (verified on the install) — so they were wrongly drawn with IBM.PAL. Added `AssetLibrary.palette(named:)` + `AssetDetailView.contextPalette(for:)` reproducing the runtime loads: mercenary mentat (`MENSHPM.SHP`/`MENTATM.CPS`) → `BENE.PAL`; cutscene WSAs (`INTRO*`/`?FINAL*`) → `INTRO.PAL`; others → IBM.PAL. Corrected the earlier (non-working) MENSHPM "fix". Insight `render-contextual-palette` (rewritten). (Committed `ad67e38`.)
- **Function-parity harness + RNGs (Phase 2/3 start).** Headless OpenDUNE oracle builds here; added `--parity-golden` function-dump mode. Ported `Random256` + `RandomLCG` to `DuneIIWorld/Rng/`, golden-verified bit-for-bit (3 tests). Docs: `Architecture/FunctionParityHarness.md`, `Algorithms/Rng.md`. (Committed `2addd51`.)
- **Tile geometry + orientation.** `Tile32` (pack/unpack, distance/direction) + `Orientation` in `DuneIIWorld/Tile/`, golden-verified (`TileGoldenTests`, 7 tests). Per-category golden fixtures (`--parity-golden=<dir>`) + shared `GoldenFixture` loader. Doc `Algorithms/Tile.md`. See History 2026-05.
- **`Tools_AdjustToGameSpeed` + index helpers.** `Tools.adjustToGameSpeed` + `Tools.indexType`/`indexDecode` (`IndexType`) in `DuneIIWorld/Tools/`, golden-verified (`ToolsGoldenTests`, 3 tests; `gamespeed-`/`index-golden.jsonl`). `Tools_Index_Encode`/`IsValid`/`Get*` deferred to the World model. Doc `Algorithms/Tools.md`. See History 2026-05.
- **Stat tables (World model start).** `HouseInfo` + `HouseID` (Contracts); `LandscapeInfo` + `LandscapeType`/`MovementType`; `ActionInfo` + `ActionType`/`SelectionType` — all in `DuneIIWorld/Stats/`, golden-verified field-for-field (`HouseInfoGoldenTests` 1 + `StatTableGoldenTests` 2; `houseinfo-`/`landscapeinfo-`/`actioninfo-golden.jsonl`). Doc `Algorithms/StatTables.md`. See History 2026-05.

## Test status

`cd Code && swift test`: **85 tests, all green** (format/codec/EMC/IconMap + PNG/WAV export + renderer services + **golden parity vs OpenDUNE** (RNG, tile geometry, game-speed, index, stat tables), synthetic + real-data). Clean build (`swift package clean && swift build`): zero warnings (full output audited, incl. the `rendertest` product). OpenDUNE oracle: `cd Repositories/OpenDUNE && PATH="$PWD/.shim:$PATH" ./configure --with-sdl2="$PWD/.shim/sdl2-config" && PATH="$PWD/.shim:$PATH" make -j4` → `./bin/opendune`.

## Open decisions (from Plan.v1.md §8)

1. Package layout — proceeding with `Code` single-package multi-target as planned (swift-tools 6.3, macOS 26). Adjust if desired.
2. `assetgen` + `Resources/` regenerate fresh in Phase 1 (planned).
3. OpenDUNE oracle tooling stood up in Phase 1–2.
4. Multi-window UI tech (Catalyst `UIScene` vs AppKit) — decide at Phase 6.

## Self-review tracker

Baseline tag: `selfreview-phase1` (set at the Phase 1 commit). Commits since = `git rev-list --count selfreview-phase1..HEAD`. Trigger: each completed phase, or every 32 commits. See CLAUDE.md → "Periodic self-review." Phase 0 review: nothing recurrent (first phase). Phase 1 review (done): recurring issue = build warnings hidden by `tail`; strengthened CLAUDE.md step 5 (read full build output) and captured insight `build-swiftpm-unhandled-files`.
