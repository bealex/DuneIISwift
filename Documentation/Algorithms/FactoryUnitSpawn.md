# Factory completion — `UnitInfo.buildTime` + unit spawn on READY (slice 5b-build)

Status: Drafted 2026-04-21 (P5 slice 5b-build — closes the factory loop).

Slice 5b-select+units let the player click a factory and see a unit sidebar with a progress bar, but the progress bar used the yard's `buildTime` (close-but-wrong) and READY clicks logged "deferred" with no unit spawn. Slice 5b-build fixes both:

1. Ports `UnitInfo.buildTime` (27 rows) from OpenDUNE.
2. Dispatches the countdown source in `startConstruction`: CY → produced structure's buildTime; factory → produced *unit's* buildTime.
3. Introduces `Simulation.Units.createUnit(...)` that allocates + places a fresh unit at a tile.
4. Introduces `Simulation.Structures.completeConstruction(...)` — port of the "READY → unit placement" tail of OpenDUNE's factory code; on a READY factory, spawns the produced unit at the factory anchor tile (rally-point heuristic deferred) and returns the yard to IDLE.
5. Scene routes READY factory clicks to `completeConstruction` instead of the deferred log.

References:

- `src/structure.c:Structure_BuildObject` — the existing reference for production queue + completion.
- `src/unit.c:Unit_Create` — the full constructor we don't yet port; we do a narrow `Units.createUnit` that covers the factory-spawn case.
- `src/table/unitinfo.c` — `buildTime` field.

## 1. `UnitInfo.buildTime`

27 values from `src/table/unitinfo.c`. Summary:

| type | name              | buildTime |
|------|-------------------|-----------|
| 0    | Carryall          | 64        |
| 1    | Thopter           | 96        |
| 2    | Infantry          | 32        |
| 3    | Troopers          | 56        |
| 4    | Soldier           | 32        |
| 5    | Trooper           | 56        |
| 6    | Saboteur          | 48        |
| 7    | Launcher          | 72        |
| 8    | Deviator          | 80        |
| 9    | Tank              | 64        |
| 10   | Siege Tank        | 96        |
| 11   | Devastator        | 104       |
| 12   | Sonic Tank        | 104       |
| 13   | Trike             | 40        |
| 14   | Raider Trike      | 40        |
| 15   | Quad              | 48        |
| 16   | Harvester         | 64        |
| 17   | MCV               | 80        |
| 18+  | projectiles/misc  | 0         |

Added with default `0` on the explicit init so only the 18 non-zero rows need updating.

## 2. `startConstruction` dispatches by yard kind

```swift
if slot.type == 8 /* CYARD */ {
    buildTime = StructureInfo.lookup(objectType).buildTime
} else {
    // Slice 5b-build: factory uses produced unit's buildTime.
    buildTime = UnitInfo.lookup(objectType).buildTime
}
```

Both paths validate that `objectType` is in range before the lookup.

## 3. `Simulation.Units.createUnit(type:houseID:tileX:tileY:pool:) -> Int?`

Narrow port of `Unit_Create`. Does enough for factory completion to produce a usable unit:

```swift
@discardableResult
public static func createUnit(
    type: UInt8, houseID: UInt8, tileX: Int, tileY: Int,
    pool: inout UnitPool
) -> Int?
```

Behaviour:

```
if houseID >= 6 || type >= 27: nil
info = UnitInfo.lookup(type) (nil → fail)
idx = pool.allocateForType(type: type, houseID: houseID) (nil → pool full)
slot = pool[idx]
slot.hitpoints = info.hitpoints
slot.positionX = tileX * 256 + 128      # centered pos32
slot.positionY = tileY * 256 + 128
slot.seenByHouses = 0xFF                # matches scenario spawn path
slot.speed = 255 for wingers, 0 otherwise
pool[idx] = slot
return idx
```

Deferred (vs OpenDUNE `Unit_Create`):

- `Script_Load` — the scheduler picks up new slots on the next tick via `findArray`; scripts bind on first-access in the existing engine-per-slot array.
- `Tile_RemoveFogInRadius` + `seenByHouses` per-house OR-in — we use the same `0xFF` shortcut the scenario-spawn path uses.
- `linkedID` initialisation — left at the `allocateForType` default.
- MCV-specific deploy logic.
- Orientation — slot init keeps `orientationCurrent = 0` (north-facing).

## 4. `Simulation.Structures.completeConstruction(yardIndex:pool:unitPool:) -> Int?`

```swift
@discardableResult
public static func completeConstruction(
    yardIndex: Int,
    pool: inout StructurePool,
    unitPool: inout UnitPool
) -> Int?
```

Behaviour:

```
guard yardIndex in range, slot.isUsed, slot.isAllocated: nil
guard slot.state == READY: nil
guard slot.type in factory set (3, 4, 5, 7, 10) — CY not handled here: nil
guard slot.objectType < 27: nil

# Spawn at the factory anchor tile. Rally-point heuristic deferred —
# the unit will visually overlap the building; player can move it off.
ax = slot.positionX / 256
ay = slot.positionY / 256
unitIdx = Units.createUnit(type: slot.objectType, houseID: slot.houseID,
                            tileX: ax, tileY: ay, pool: &unitPool)
if unitIdx == nil: return nil  # pool full; yard stays READY for retry

slot.state = IDLE
slot.objectType = 0xFFFF
slot.countDown = 0
pool[yardIndex] = slot
return unitIdx
```

CY completion stays on the existing click-map-to-place path in `ScenarioScene.commitPlacement` — it requires a player-chosen tile for placement, not an automatic spawn. That asymmetry matches OpenDUNE's own distinction between `Structure_BuildObject` (unit factories auto-place) and `GUI_WidgetClick_ObjectPlace` (structure yards need player click).

## 5. Scene wiring

`ScenarioScene.mouseDown`'s `.enterPlacement` case for factories currently logs "unit spawn deferred". Slice 5b-build replaces that with a call to `Structures.completeConstruction`, refreshes the sidebar, and logs the outcome:

```swift
case .enterPlacement(let type):
    if currentYardKind == .unit {
        completeFactoryProduction(yardIndex: yardIdx)  // new helper
    } else {
        // existing CY placement-mode entry
    }
```

`completeFactoryProduction(yardIndex:)` on the scene:

```swift
var structures = host.structures
var units = host.units
if let unitIdx = Simulation.Structures.completeConstruction(
    yardIndex: yardIdx, pool: &structures, unitPool: &units
) {
    host.structures = structures
    host.units = units
    Log.info("build-panel: factory completed type=... → unit slot=\(unitIdx)",
             tracer: .label("build-panel"))
    buildController.placementType = nil
    refreshBuildSidebar()
}
```

## 6. What slice 5b-build does NOT cover

- **Rally point / south-of-factory exit tile.** Current spawn is at the factory anchor, overlapping the building. Player moves the unit off manually. Slice 5c (HUD + rally point) tightens.
- **Credit drain during construction.** Still deferred.
- **Per-tick HP decay consuming the `degrades` flag.**
- **Unit scripts** — scheduler picks up new units on next tick; `orientationCurrent = 0` (north-facing) until the unit's AI chooses.
- **STARPORT's CHOAM trade queue.**
- **`Unit_Create` side effects:** `Script_Load`, fog uncovering, MCV special deploy, linkedID init. Slice 5b-build covers the narrow subset the factory flow needs.

## 7. Testing

Extend `FactoryBuildableTests`:

- `startConstruction` on LV factory with TRIKE: `countDown == 40 << 8 = 10240` (not 96<<8 placeholder). Pin UnitInfo-sourced countdown.
- `startConstruction` on BARRACKS with SOLDIER: `countDown == 32 << 8 = 8192`.
- `startConstruction` on HV factory with TANK: `countDown == 64 << 8 = 16384`.

New `UnitCreateTests` or similar:

- `Units.createUnit` with valid type + in-range tile → non-nil index, slot populated.
- `Units.createUnit` with out-of-range houseID → nil.
- `Units.createUnit` with out-of-range type → nil.
- Centered pos32 equals `(tileX * 256 + 128, tileY * 256 + 128)`.
- Full pool → nil.

New tests in `FactoryBuildableTests` or separate suite:

- `completeConstruction` on READY BARRACKS with SOLDIER queued → spawns unit at factory anchor, yard flips to IDLE, objectType reset.
- `completeConstruction` on BUSY factory → nil.
- `completeConstruction` on READY CY → nil (CY completion is map-click-placement, not auto).
- `completeConstruction` on READY non-factory (e.g. REFINERY) → nil.
- Full unit pool → yard stays READY, no pool mutation observed.

## 8. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift` — `buildTime` field + 18 non-zero rows.
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `startConstruction` dispatch + `completeConstruction`.
- `Code/Core/Sources/DuneIICore/Simulation/Units.swift` — `createUnit`.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — READY factory click routes to `completeConstruction`.
- `Code/Core/Tests/DuneIICoreTests/FactoryBuildableTests.swift` — extended.
