# Structure construction — state machine + `tickConstruction` (slice 4d-sim)

Status: Drafted 2026-04-21 (P5 slice 4d-sim — pure-simulation countdown state machine, no UI yet).

Slices 1–4c gave the player clicks: sidebar shows what's buildable, map clicks validate and instantly stamp a structure. Slice 4d closes the behavioural gap: construction takes time. Clicking a sidebar slot flips the owning construction yard into `STRUCTURE_STATE_BUSY` and a scheduler pass drains `countDown` each tick until the yard becomes `STRUCTURE_STATE_READY`. Placement commits only go through on READY yards.

This doc covers the sim-layer port (`startConstruction`, `tickConstruction`, scheduler wiring, `buildTime` data). The UI layer (sidebar progress bar, click gating) lands in slice 4d-ui.

References:

- `src/structure.c:Structure_BuildObject` — the actual OpenDUNE function; we port its tail (after the factory-window / starport branches).
- `src/structure.c:Structure_SetState` — one-liner writing `state` + calling `Structure_UpdateMap` (map-paint deferred).
- `src/gui/gameloop.c:GameLoop_Structure` — where the per-tick `countDown` decrement actually runs in OpenDUNE.
- `src/table/structureinfo.c` — `buildTime` field.

## 1. `StructureInfo.buildTime`

New `UInt16` field. Per-type values (from `src/table/structureinfo.c`):

| type | name              | buildTime |
|------|-------------------|-----------|
| 0    | SLAB_1x1          | 16        |
| 1    | SLAB_2x2          | 16        |
| 2    | PALACE            | 130       |
| 3    | LIGHT_VEHICLE     | 96        |
| 4    | HEAVY_VEHICLE     | 144       |
| 5    | HIGH_TECH         | 120       |
| 6    | HOUSE_OF_IX       | 120       |
| 7    | WOR_TROOPER       | 104       |
| 8    | CONSTRUCTION_YARD | 80        |
| 9    | WINDTRAP          | 48        |
| 10   | BARRACKS          | 72        |
| 11   | STARPORT          | 120       |
| 12   | REFINERY          | 80        |
| 13   | REPAIR            | 80        |
| 14   | WALL              | 40        |
| 15   | TURRET            | 64        |
| 16   | ROCKET_TURRET     | 96        |
| 17   | SILO              | 48        |
| 18   | OUTPOST           | 80        |

Added with a default `0` on the memberwise init so the 19 `StructureInfo.table` rows get explicit values but no other code needs updates.

## 2. `Simulation.StructureState` namespace

Lightweight enum / typed constants over the existing `StructureSlot.state: Int16`:

- `DETECT = -2` (write-only sentinel)
- `JUSTBUILT = -1`
- `IDLE = 0`
- `BUSY = 1`
- `READY = 2`

Exposed as `public enum StructureState` with `rawValue: Int16`. Existing code that compares `slot.state == -1` etc. continues to compile (integer comparison still works). New code uses `slot.state == Simulation.StructureState.busy.rawValue` for readability.

## 3. `Simulation.Structures.startConstruction`

Port of `Structure_BuildObject`'s tail (the path taken after the factory window picks an `objectType` for a CONSTRUCTION_YARD). Signature:

```swift
@discardableResult
public static func startConstruction(
    yardIndex: Int,
    objectType: UInt8,
    pool: inout StructurePool
) -> Bool
```

Behaviour:

```
guard yardIndex is in range and slot.isUsed and slot.isAllocated: return false
guard slot.type == CYARD (== 8): return false
guard objectType < 19: return false
guard slot.state != BUSY: return false        # already building
guard info = StructureInfo.lookup(objectType): return false

slot.objectType = objectType
slot.countDown = info.buildTime << 8
slot.state = BUSY
return true
```

Deliberate deviations from OpenDUNE:

- **No pre-allocated placeholder structure.** `Structure_BuildObject` calls `Structure_Create(STRUCTURE_INDEX_INVALID, objectType, houseID, 0xFFFF)` to allocate a "linked" ghost structure with `isNotOnMap=true`; that's its way of reserving a pool slot for the result. We allocate at placement commit instead. Functionally equivalent for the player; simpler state model.
- **No credit drain.** OpenDUNE's `GameLoop_Structure` subtracts credits from the house per tick while building. Deferred until house-credits + HUD land. Slice 4d lets the player build free.
- **No `onHold` / `Structure_CancelBuild`.** Re-clicking the sidebar during construction is a no-op in slice 4d (the `state != BUSY` guard). Slice 4d-ui may add cancel.
- **No repairing / upgrading branches.** Only the plain build path.
- **`Structure_SetState` side-effects.** OpenDUNE calls `Structure_UpdateMap` to repaint animated-tile frames (busy construction yards wobble). Deferred.

## 4. `Simulation.Structures.tickConstruction`

Port of the `countDown` decrement portion of `GameLoop_Structure`:

```swift
public static func tickConstruction(pool: inout StructurePool)
```

```
for idx in pool.findArray:
    slot = pool[idx]
    if not BUSY: continue
    buildSpeed: UInt16 = 256        # slice-4d-sim constant; slice-4d+
                                    # scales by house tech + game speed.
    if slot.countDown > buildSpeed:
        slot.countDown -= buildSpeed
    else:
        slot.countDown = 0
        slot.state = READY
    pool[idx] = slot
```

Decrementing by 256 per tick means the countdown completes in `buildTime` ticks. With the existing Scheduler running at 5-frames-per-tick (~12 Hz at 60fps), a WINDTRAP (`buildTime = 48`) takes 48/12 ≈ 4 s to complete — feels right vs. OpenDUNE at default game speed.

The 256-per-tick constant mirrors the `<< 8` packing of `countDown`. When credit drain and game-speed scaling land (later slice), `buildSpeed` becomes a per-yard value fed from `House.buildSpeed` + scenario tables.

## 5. `Scheduler.tick()` integration

Scheduler already has a `tickMovement` / `tickFireCooldowns` / `tickExplosions` family of pre-script passes. Add `tickConstruction(pool:)` to that sequence — runs before the per-slot EMC script dispatch:

```swift
// In Scheduler.tick():
Simulation.Structures.tickConstruction(pool: &host.structures)
// … existing pre-script passes + script dispatch …
```

Keeps construction independent of the structure VM's `BUILD.EMC` (which our slice doesn't yet wire for countdown — OpenDUNE's script also handles this in C outside the VM via `GameLoop_Structure`).

## 6. What slice 4d-sim does NOT cover

- **Credit drain** — house economy is a later slice (P5 HUD / economy).
- **`Structure_CancelBuild`** — re-clicking during BUSY does nothing for now.
- **Read of `READY` in UI** — slice 4d-ui wires the `BuildPanelController` to read yard state and gate map-click commits.
- **Structure animation** — `Structure_UpdateMap` side-effect not ported; animations (busy factories, refineries pulsing) come with renderer work.
- **Starport / factory (unit-production) paths** — this slice is CYARD-only.
- **Factory upgrades** — handled by a different branch of `Structure_BuildObject` (deferred).
- **Per-slot `linkedID` with pre-allocated ghost** — our model commits the allocation at placement time; see §3.
- **`Scheduler.tick` test coverage** — the scheduler's existing test suite didn't cover the construction pass; 4d-sim adds integration tests under `SimulationSchedulerTests` that ensure the new pass runs.

## 7. Testing

New `Tests/DuneIICoreTests/StructureConstructionTests.swift` suite:

### `StructureInfo.buildTime` data

- `table[9].buildTime == 48` (WINDTRAP) — spot check + full-table iteration.

### `StructureState` constants

- Raw values match OpenDUNE (`DETECT = -2`, `JUSTBUILT = -1`, `IDLE = 0`, `BUSY = 1`, `READY = 2`).

### `startConstruction`

- Non-yard slot (e.g. WINDTRAP) → returns false; state unchanged.
- Yard slot, objectType=19 (out of range) → returns false.
- Yard slot IDLE, objectType=WINDTRAP → returns true; slot.state = BUSY, objectType = 9, countDown = 48 << 8 = 12288.
- Yard already BUSY → returns false; state unchanged.

### `tickConstruction`

- Empty pool → no-op.
- Pool with IDLE yard → state unchanged.
- Pool with BUSY yard, countDown = 12288 → after one tick countDown = 12032 (12288 - 256).
- Pool with BUSY yard, countDown = 200 → after one tick countDown = 0 and state = READY.
- Pool with BUSY yard, countDown = 256 → after one tick countDown = 0, state = READY.
- Pool with READY yard → state unchanged (tick doesn't re-arm).
- Multiple yards in varied states → each evolves independently.

### Scheduler integration

- `Scheduler.tick()` runs `tickConstruction` before script dispatch — verify by setting a yard BUSY, running one tick, observing `countDown` went down by 256.
- A full 48-tick run on a freshly-started WINDTRAP build flips the yard to READY.

## 8. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/StructureInfo.swift` — `buildTime` field + populated rows.
- `Code/Core/Sources/DuneIICore/Simulation/StructureState.swift` — new file (constants namespace).
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `startConstruction` + `tickConstruction`.
- `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift` — add `tickConstruction` pass.
- `Code/Core/Tests/DuneIICoreTests/StructureConstructionTests.swift` — new suite.
