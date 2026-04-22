# Factory rally point

Player-configurable exit destination for newly-produced units from a factory structure (LIGHT_VEHICLE, HEAVY_VEHICLE, HIGH_TECH, WOR, BARRACKS). Right-clicking a map tile while a player-owned factory is selected stamps the tile as that factory's rally point. Each subsequent unit that rolls out of the factory spawns at the usual south-of-footprint exit tile, then receives an immediate `Unit_Order(MOVE → rally)` so it drives off on its own.

This feature is our own — **OpenDUNE does not implement rally points.** `Structure_BuildObject` in `src/structure.c:1442..1681` spawns units at `Structure_FindFreePosition` with no player-configurable destination. We're keeping the sim faithful where it matters (unit creation, action dispatch) and layering a tiny rally field on top; the rally write feeds through the same `Simulation.Units.orderMove` path that the player right-click already uses, so the unit's behaviour post-spawn is indistinguishable from a click issued a frame later.

## Sim state

New field on `Simulation.StructureSlot`:

- `rallyPointPacked: UInt16` — packed `y * 64 + x` tile coordinate. Sentinel `0xFFFF` means "no rally set" (default). Uses the same `Tile_PackXY` encoding the pathfinder already assumes.

Always initialised to `0xFFFF` on every init path (pool default, `Structures.create`, `WorldSnapshot` scenario path, `WorldSnapshot` save path). Save loading does not populate rally points — rally is a UI-layer convenience that doesn't persist yet (if we ever ship save compat, the `BLDG` chunk would need a new trailing byte pair).

## Pure-sim API

```swift
// Stamps a tile rally point on a factory yard.
// Returns true on success; false when:
//  - yardIndex out of range / unallocated
//  - yard type is not one of {3, 4, 5, 7, 10}
//  - tile is off the 64×64 map
// Non-factory (CYARD, TURRET, REFINERY, etc.) rally requests are rejected.
// Clearing the rally is `setRallyPoint(... tile: nil, ...)`.
@discardableResult
static func setRallyPoint(
    yardIndex: Int,
    tile: (x: Int, y: Int)?,
    pool: inout StructurePool
) -> Bool
```

`completeConstruction` changes signature: it now takes a rally tile from the slot and, on successful spawn, calls `Units.orderMove` on the new unit with the rally tile. Order of operations:

1. Spawn at `factorySpawnTile` as today (unit's `positionX/Y` is the exit tile).
2. If `rallyPointPacked != 0xFFFF`, decode `(rx, ry)` and call `orderMove(poolIndex: unitIdx, tileX: rx, tileY: ry, units: &unitPool)`. Ignore the return — failure just leaves the unit idle, same as slice 5b-build's current behaviour.
3. Flip yard IDLE, clear `objectType` / `countDown`.

The rally tile persists across builds — one click at scene-start, ten units all roll to the same spot.

## Scene wiring

`ScenarioScene.rightMouseDown(with:)` currently routes every right-click to `commandController`. New branch:

- If `commandController.selectedUnitIndex` is set (a unit is highlighted), keep today's path — unit commands take priority.
- Else, if `buildController.selectedYardIndex` points at a player-owned factory (type 3/4/5/7/10), call `Simulation.Structures.setRallyPoint` and refresh the rally marker.
- Else, fall through (current no-op).

Visual marker: a small yellow `SKShapeNode` diamond (or hollow circle) at the rally tile, parented to the scene at `zPosition = 4`. Rebuilt whenever the selected yard changes or rally moves; hidden when no factory is selected or the selected factory has no rally set.

## Deferred

- Persistence in save files (adds bytes to `BLDG` tail).
- Rally lines (polygonal rendering of factory → rally).
- Rally onto another unit / structure (OpenDUNE-style encoded-index target). We only support tile rally.
- Alliance-aware rally (rally onto an enemy tile is allowed — the `orderMove` call simply walks the unit over; combat kicks in once it arrives).
