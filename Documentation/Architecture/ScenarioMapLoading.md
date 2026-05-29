# Scenario / map / sprite-init loading (and the map app)

Design of record for the layer that turns on-disk assets into a populated `GameState` we can simulate and draw. This is the deferred Phase-2 "scenario loading + map-from-seed + original-save converter" work; it is the prerequisite that unblocks most of Tiers D/E/F (the landscape/spice/fog primitives need the runtime tile-id bases derived here). Build bottom-up.

## Where assets live + how the engine reads them

`assetgen` already extracts the install into `Resources/` (committed): missions at `Resources/Scenarios/SCEN*.INI` + `REGION*.INI`; the tile sprites `ICON.ICN` → `Resources/Tiles/ICON.{png,json}`; the icon-group table `ICON.MAP` → `Resources/Tiles/Maps/ICON.MAP` (raw LE16). Original saves are in the install at `_SAVE00x.DAT`. Decoders exist in `DuneIIFormats` (`IconMap`, `Ini`, `Shp`/`Icn`, `Iff` for the save FORM).

Filesystem integration lives above `DuneIIFormats` (Formats take `Data`). Introduce a small **`ResourceProvider`** seam (a protocol) that maps a logical name (`"ICON.MAP"`, `"SCENA001.INI"`) to `Data`, with a `Resources/`-backed default. World/loaders depend on it; tests inject a fixture provider or the real `Resources/` dir.

## Sub-deliverables, in dependency order

1. **Sprite tile-id init** (`Sprites_Init`, `sprites.c:274`). Decode `ICON.MAP` → `IconMap`; derive the runtime bases `TileIDs` = { `veiled` = group FOG_OF_WAR(7)[16], `bloom` = SPICE_BLOOM(10)[0], `builtSlab` = CONCRETE_SLAB(8)[2], `landscape` = LANDSCAPE(9)[0], `wall` = WALLS(6)[0] }. Stored in `GameState.tileIDs`, populated at load. (Real-data values: veiled 124, bloom 208, builtSlab 126, landscape 127, wall 33.) **This unblocks `Map_GetLandscapeType`.** ← first.
2. **`Map_GetLandscapeType`** (`map.c`, Tier D #11) — now portable (tile-id bases + `_landscapeSpriteMap` + structure pool). Golden-verified against the load-mode per-tile `Parity_DumpLandscape` once a map is loaded (3).
3. **Original-save conversion** (`save.c`/`load.c` + `saveload/*` descriptor tables). Parse the `_SAVE00x.DAT` `FORM` (chunks: `SCEN`/`NAME`/`INFO`/`MAP`/`POOLS`/object arrays/…) via `Iff` → populate `GameState` (the `MapTile[64*64]` grid, pools, houses, `mapScale`, `playerHouseID`, clocks, RNG). This is the fastest route to a **drawable map** (the save holds the full `g_map`), and gives the oracle pairing for (2). Then write our own save format + round-trip. Behavioural-faithful, not bit-identical (Plan §7).
4. **Mission loading** (`scenario.c`/`ini.c`). Parse `SCEN*.INI` sections (`BASIC`, `MAP`, `UNITS`, `STRUCTURES`, `TEAMS`, `REINFORCEMENTS`, `CHOAM`) → `GameState`. `BASIC/MapScale`, `BASIC/Seed`, the player house, etc.
5. **Map-from-seed** (`Map_CreateLandscape`, `map.c`) — generate the landscape grid from `BASIC/Seed` (LCG + spread passes). Needed for a fresh mission (vs. a loaded save).
6. **Tile → sprite render mapping** — a `MapTile.groundTileID` → `ICON.ICN` tile index lookup (the icon already extracted), so a render layer can draw the grid. Pixel-faithful per the existing `IndexedImage`/palette services.

`Map_GetLandscapeType` golden-verification reuses the existing oracle `--parity-load` mode (`Parity_DumpLandscape` already dumps `Map_GetLandscapeType` for all 4096 tiles); load the same `_SAVE00x.DAT` on both sides and diff.

## The map app (after a map is loadable + drawable)

A SwiftUI app showing the map, **macOS + iOS ready**. Per `CLAUDE.md` the eventual host is `duneii` (the multi-window verification UI); this is its first window.

- **For now:** one resizable main window; a toolbar with scale buttons **1× / 2× / 4× / 8× / 16×**; the map view fills the window (resizable) and scales nearest-neighbour (pixel-faithful) at the chosen factor.
- **Multiplatform:** SwiftUI views + a view model in a small UI library/target; the map image comes from the render mapping (6) over a loaded `GameState`. SPM executables are macOS-only, so an iOS-ready host needs an Xcode multiplatform app (or Mac Catalyst) — **decide the target when we reach the app chunk**; keep the views host-agnostic (Contracts-bound) so both hosts are thin.

## Status

Sub-deliverable 1 (sprite tile-id init) lands first; the rest follow in order. Tracked in `CurrentState.md`.
