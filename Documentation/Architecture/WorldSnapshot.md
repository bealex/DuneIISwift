# WorldSnapshot

`Simulation.WorldSnapshot` is the bridge from "typed save file" to "live world state". It takes a decoded `Formats.Save.Game` plus a `Map` baseline (the map-seed-generated terrain) and produces a world the simulation can query: three populated pools and a dense 4096-cell tile grid with sparse overrides applied.

It is a value type, produced by a single `throws` initializer. It does **not** own EMC programs, does **not** restart script execution, and does **not** touch scenario-level AI state. Those are separate layers.

References:

- `Formats.Save.Game` · `Documentation/Formats/SAVE.md` §12
- Pools · `Documentation/Architecture/Pools.md`
- Map generation · `Documentation/Algorithms/MapGenerator.md`

## 1. Contract

```swift
public struct Simulation.WorldSnapshot {
    public let houses: Simulation.HousePool
    public let units: Simulation.UnitPool
    public let structures: Simulation.StructurePool
    public let tiles: [Tile]   // length = Map.width × Map.height = 4096

    public init(loading game: Formats.Save.Game, baseline: Map) throws
}
```

The initializer walks the save's record arrays in file order and reproduces them on top of the baseline:

1. **Houses.** For each `Save.Player.HouseSlot`, allocate the matching `Simulation.HousePool` slot at `slot.index`. Copy `starportLinkedID`. `HouseFlags` bits that don't land in the pool yet (`human`, `radarActivated`, …) are kept on the `Save.Player.HouseSlot` record — the pool stays minimal.
2. **Units.** For each `Save.Units.Slot`, allocate the matching `Simulation.UnitPool` slot at `slot.object.index` with the record's `type` / `houseID`; copy `linkedID` from the Object header.
3. **Structures.** Same, with two wrinkles: indices in `[0, 78]` route through `allocate(at:type:houseID:)`; indices in `[79, 81]` (the reserved walls/slabs aggregates) route through `allocateReserved(at:type:)`. Real 1.07 saves don't emit reserved indices — the defensive branch is there in case OpenDUNE-produced saves start using them.
4. **Tiles.** Start from the `baseline` (map-seed-generated `Map.Cell` grid, ground + overlay IDs in place). For each cell, synthesise a `WorldSnapshot.Tile` carrying the baseline's ground and overlay. Then walk `game.tileMap.entries` and *replace* the tile at each `cellIndex` with the decoded sparse `Tile`.

## 2. `WorldSnapshot.Tile`

The dense tile grid is not a `Map`. It's a fresh record type that mixes baseline terrain with save-specific fog / ownership / pool-reference bits. This is intentional — `Map.Cell` is what the scenario stamps onto a fresh map, and the save chunk carries strictly more per-cell state (fog mask per *tile*, not per house; live unit / structure presence; on-going animations and explosions).

```swift
public struct Tile: Sendable, Equatable {
    public let groundTileID: UInt16
    public let overlayTileID: UInt16  // widened from 7-bit TileMap.Tile value
    public let houseID: UInt8         // 3-bit owner
    public let isUnveiled: Bool
    public let hasUnit: Bool
    public let hasStructure: Bool
    public let hasAnimation: Bool
    public let hasExplosion: Bool
    /// Pool-index-plus-one. `0` = no object on this tile, `n` = Unit or
    /// Structure at pool index `n - 1`. Distinguish unit vs. structure via
    /// the `hasUnit` / `hasStructure` flags.
    public let objectRef: UInt8
}
```

## 3. Invariants and failure modes

The initializer throws on cross-chunk inconsistency the save-format decoders didn't catch at the byte level:

| Case                                    | Triggered by                                                             |
|-----------------------------------------|--------------------------------------------------------------------------|
| `.duplicateHouseIndex(UInt16)`          | Two `PLYR` slots share `index`, or `index` ≥ 6.                          |
| `.unitIndexOutOfRange(UInt16)`          | A `UNIT` record carries `object.index` ≥ 102.                            |
| `.duplicateUnitIndex(UInt16)`           | Two `UNIT` records share `object.index`.                                 |
| `.structureIndexOutOfRange(UInt16)`     | A `BLDG` record carries `object.index` ≥ 82.                             |
| `.duplicateStructureIndex(UInt16)`      | Two `BLDG` records share `object.index`.                                 |

Baseline cell count is not validated here — `Map.init` already asserts `cells.count == 64 × 64`, so by the time a `Map` instance exists, it's guaranteed 4096 cells.

Everything else (the specific values of `hitpoints`, `flags`, `scriptState.delay`, etc.) is accepted verbatim. Bounds-checking higher-level meaning is the simulation layer's job.

## 4. What the `objectRef` off-by-one means here

The save format stores `tileIndex` as `(poolIndex + 1)` with `0` sentinelling "no object". We preserve that verbatim in `WorldSnapshot.Tile.objectRef`. Callers that want the pool slot write `Int(objectRef) - 1`, guarding against `objectRef == 0` first. The off-by-one is documented once more at the declaration site and in `format-save-map-is-sparse-not-fixed.md`; translating away from it happens one layer above.

## 5. What `WorldSnapshot` does not do

- **EMC resumption.** Each `Save.Units.Slot` / `Save.Structures.Slot` carries a `ScriptState` block with `scriptOffset` and variable/stack arrays. We surface those on the pool slots as-is; wiring them into a `Scripting.VM` requires pairing each object with its entry-point in `UNIT.EMC` / `BUILD.EMC`, which is a separate concern.
- **Fog reconstruction.** The baseline's `overlayTileID` carries whatever `Map.Generator` produced, not `veiledTileID`. A caller that wants accurate fog must overlay `veiledTileID` onto cells that are *not* in `game.tileMap.entries`. We don't do that here because it requires the `TileResolver` the baseline was built with, which may not be available at snapshot time.
- **Tile → Simulation cross-links.** If a tile's `objectRef` claims unit index 12 but the corresponding slot is `!isUsed`, we don't flag it. Cross-reference validation lives at the simulation tick layer.

## 6. Test coverage

- `SimulationWorldSnapshotTests.swift:realSave001` — real-data `_SAVE001.DAT` decode assert that house allocation matches `humanSlot`, units and structures populate allocated pools, and the dense tile grid has 4096 entries with the sparse overrides visible at their expected cell indices.
- Synthetic composition tests pin: (a) a single-house, single-unit, single-structure save composes cleanly; (b) duplicate house / unit / structure indices throw; (c) out-of-range indices throw; (d) a tile at a known cell index overwrites the baseline ground while leaving other cells untouched; (e) baselines with wrong cell count are rejected.

## 7. Not covered

- ODUN merge. When an OpenDUNE-produced save is loaded, `game.unitsNew` is a raw `Data?` and we don't patch the high byte of `fireDelay` or the `deviatedHouse` field. Our corpus has no such saves; ODUN parsing + merge lands the first time it's needed.
- TEAM restoration. `game.team` is raw `Data?`; AI team membership mapping waits on the team-scripting layer.
