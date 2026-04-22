# Spice repaint on `SpiceMap.apply` (slice 9)

Gap: harvesters drain spice via `Simulation.SpiceMap.apply` each tick, but the tile's `groundTileID` stays pinned to the original spice sprite. Visually, a fully drained tile reads as full spice forever. This slice connects the logical level transitions back to the tile grid so the scene (and the minimap / screenshot renderer) shows the drain in real time.

## OpenDUNE reference

`src/map.c:771` — `Map_ChangeSpiceAmount(packed, dir)`:

```c
spriteID = 0;
if (type == LST_SPICE)       spriteID = 49;
if (type == LST_THICK_SPICE) spriteID = 65;
spriteID = g_iconMap[g_iconMap[ICM_ICONGROUP_LANDSCAPE] + spriteID] & 0x1FF;
g_mapTileID[packed] = 0x8000 | spriteID;
g_map[packed].groundTileID = spriteID;
Map_FixupSpiceEdges(packed);
…
```

Level → sprite offset into the landscape icon group:

| Level | Offset |
|---|---|
| bare / normal sand | 0 |
| thin spice (`LST_SPICE`) | 49 |
| thick spice (`LST_THICK_SPICE`) | 65 |

`Map_FixupSpiceEdges` then blends the 4-neighbour sprite IDs to smooth out hard edges. Deferred — first pass uses the raw offset per level; edge fixup can come later.

## Wiring

1. `Scripting.Host` gains `var spiceLevelDidChange: ((_ packed: UInt16, _ level: Simulation.SpiceMap.Level) -> Void)?`.
2. `Scheduler.tickHarvesting` wraps the existing `changeSpice` closure to capture the `before` level, call `spiceMap.apply`, and — when `before != after` — invoke `host.spiceLevelDidChange?(packed, after)`.
3. `ScenarioRuntime.load` installs a closure that maps the `Level` to a `groundTileID` via the scene's `TileResolver` + iconMap, and writes it into `tileGridRef.tiles[cellIdx].groundTileID`.
4. Existing `ScenarioScene.syncGroundTiles()` picks up the change on the next tick — no scene-side plumbing needed.

The runtime closure ignores `.notSand` transitions (can't happen — `apply` bails on non-sand cells).

## Tests

- `SpiceMapRepaintTests`
  - **Transition callback fires**: synthetic scheduler + harvester on a thick spice tile; after the drain, `spiceLevelDidChange` closure records a `(packed, thin)` entry.
  - **No callback when level stays**: two back-to-back drains on bare → no fires; two `+1`s on thick → no fires.
  - **GroundTileID overwritten**: install-gated runtime test. Load mission 1 → place a harvester on a known thick-spice tile → tick until drain → assert `runtime.tileGrid[cellIdx].groundTileID` matches `iconMap.tileId(in: .landscape, offset: 49)` (spice) then eventually `0` (sand).

## Out of scope

- Edge fixup (`Map_FixupSpiceEdges`).
- Spice regrowth (`Map_UpdateSpice` — deferred to a later slice).
- Minimap redraw: the existing renderer re-samples tile state per tick, so it picks up the new level automatically.
