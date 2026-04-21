# Firing — `Script_Unit_Fire` + `Unit_CreateBullet`

Status: Drafted 2026-04-20 (P4 Phase 4 — second slice; target acquisition already landed).

Once a unit has picked a target (via `Script_Unit_FindBestTarget`), the EMC script calls `Script_Unit_Fire` (slot 0x08) to spit a bullet (or eat, for sandworms). This doc covers the port of both `Script_Unit_Fire` and the `Unit_CreateBullet` it calls.

References:

- `src/script/unit.c:577` — `Script_Unit_Fire`.
- `src/unit.c:1954` — `Unit_CreateBullet`.
- `src/unit.c:391` — `Unit_Create` (full unit allocation, shared with non-bullets).
- `src/pool/unit.c:107` — `Unit_Allocate` (the per-type index-range allocator).
- `src/table/unitinfo.c` — `indexStart` / `indexEnd` / `bulletType` / `firesTwice` per type.

## 1. Bullets live in the UnitPool

OpenDUNE doesn't use a separate projectile pool. Bullets are units of type `UNIT_BULLET` (23), `UNIT_SONIC_BLAST` (24), or one of the five missile types (18..22). They occupy slots in the same 102-capacity `UnitPool` that every other unit lives in, and they run their own EMC scripts (`BULLET.EMC` via the script table).

What keeps them from colliding with "real" units is the per-type index range stamped on every `UnitInfo` row: `indexStart..indexEnd`. `Unit_Allocate(UNIT_INDEX_INVALID, type, houseID)` walks that range looking for the first unused slot. The allocation layout ported from vanilla 1.07:

| Type                 | ID  | Range     | Concurrent cap |
|----------------------|-----|-----------|----------------|
| CARRYALL / ORNITHOPTER | 0, 1 | 0..10    | 11 |
| FRIGATE              | 26  | 11..11    | 1  |
| MISSILE_* / BULLET / SONIC_BLAST | 18..24 | 12..15 | 4  |
| SANDWORM             | 25  | 16..17    | 2  |
| SABOTEUR             | 6   | 20..21    | 2  |
| everything else (troops + vehicles) | 2..5, 7..17 | 22..101 | 80 |
| (unused)             | —   | 18..19    | — |

The 4-bullet cap is a real gameplay constraint — it's why the original Dune II has a noticeable bullet queue during large engagements, and why we must not silently bump it.

## 2. `UnitInfo` field additions

Four new fields land on `UnitInfo` to feed Fire + CreateBullet:

```swift
public let indexStart: UInt16       // per-type pool slice
public let indexEnd: UInt16
public let bulletType: UInt8?       // UNIT_INVALID → nil
public let firesTwice: Bool         // double-tap for "firesTwice" units
```

Values for all 27 entries are lifted row-by-row from `src/table/unitinfo.c`.

`bulletType` lookup table (non-nil rows only):

| Shooter           | Bullet             |
|-------------------|--------------------|
| ORNITHOPTER (1)   | MISSILE_TROOPER    |
| INFANTRY (2)      | BULLET             |
| TROOPERS (3)      | BULLET             |
| SOLDIER (4)       | BULLET             |
| TROOPER (5)       | BULLET             |
| SABOTEUR (6)      | MISSILE_ROCKET     |
| LAUNCHER (7)      | MISSILE_DEVIATOR   |
| DEVIATOR (8)      | BULLET             |
| TANK (9)          | BULLET             |
| SIEGE_TANK (10)   | BULLET             |
| DEVASTATOR (11)   | SONIC_BLAST (`ui.bulletType = UNIT_SONIC_BLAST`) — wait: see note |
| SONIC_TANK (12)   | BULLET             |
| TRIKE (13)        | BULLET             |
| RAIDER_TRIKE (14) | BULLET             |
| QUAD (15)         | BULLET             |
| SANDWORM (25)     | SANDWORM (self-referential — "eat" branch, no bullet created) |

*Note*: the exact bullet-per-type map is read from the inline comments in `src/table/unitinfo.c` rather than memorised — the table above is for reader orientation, not the source of truth. The Swift table copies the C verbatim.

## 3. `UnitSlot` runtime fields

Two new slot fields needed for Fire's timing and firesTwice:

```swift
public var fireDelay: UInt8         // ticks until next shot (runtime cooldown)
public var fireTwiceFlip: Bool      // flip-flop for the double-tap
```

`fireDelay` is the decrementing counter written by `Script_Unit_Fire` at the end of the function and read on its guard early in the next call. The save format already carries this (`SaveUnits.Slot.fireDelay`, narrowed from u16→u8 via `ODUN` in OpenDUNE saves; vanilla saves use the u8 directly).

`fireTwiceFlip` toggles each fire for units with `firesTwice` = true (TANK, SIEGE_TANK, QUAD, DEVASTATOR, RAIDER_TRIKE, LAUNCHER, ORNITHOPTER). When the flip is set, the next shot fires quickly (≈5 ticks) rather than after the full reload — that's the "tak-tak" double-tap in the original.

## 4. `UnitPool.allocateForType(type:houseID:)`

New method. Uses the type's `indexStart..indexEnd` range, walks until it finds an unused slot, calls the existing `allocate(at:type:houseID:)`. Returns `nil` when the range is full. Mirrors `Unit_Allocate`'s "index == 0 || index == UNIT_INDEX_INVALID" path.

```swift
public mutating func allocateForType(type: UInt8, houseID: UInt8) -> Int?
```

Out-of-range type (≥ UNIT_MAX = 27) → `nil`.

We deliberately skip OpenDUNE's house `unitCount >= unitCountMax` gate: that needs `HouseSlot.unitCount` + `g_table_houseInfo`, neither of which is ported yet. Ground units will "leak" the cap until P4 Phase 5; bullets don't trigger the check anyway (winger exception).

## 5. `Simulation.Units.createBullet(...)`

Port of `Unit_CreateBullet` (`src/unit.c:1954`). Namespaced under a new `Simulation.Units` enum (following the `Simulation.House` pattern) so it can be called from both the script-slot wrapper and whatever test harness we use.

Signature:

```swift
public static func createBullet(
    position: Pos32,
    type: UInt8,
    houseID: UInt8,
    damage: UInt16,
    target: UInt16,                       // encoded index
    host: Scripting.Host,
    random: RandomSource? = nil           // for notAccurate drift
) -> Int?                                 // new bullet's pool index, nil on fail
```

Steps (verbatim from the C):

1. If `target` is not `Tools_Index_IsValid` → return nil.
2. Look up the target tile (`Pos32.of(encoded, host:)`).
3. Switch on bullet type:
   - **MISSILE_* (18..22)**: orientation = `Tile_GetDirection(position, targetTile)`. Allocate a unit of `type` at `position` with that orientation. Set `targetAttack = target`, `hitpoints = damage`, `currentDestination = targetTile`. `fireDelay = ui.fireDistance & 0xFF` (then doubled when the target is a winger — a sanity-check for manned AA). Deferred: `notAccurate` random drift, `bulletSound` voice, fog removal.
   - **BULLET / SONIC_BLAST (23, 24)**: orientation = `Tile_GetDirection(position, targetTile)`. Shift the spawn position forward by `MoveByDirection(position, 0, 32)` then `MoveByDirection(..., orientation, 128)` (essentially: step off the shooter's tile so the bullet doesn't hit them). Allocate, set `targetAttack`, `hitpoints = damage`, `currentDestination = targetTile`. For `SONIC_BLAST`, also seed `fireDelay = ui.fireDistance & 0xFF` (decrements as the beam travels).
   - **else**: `nil` (includes `UNIT_INVALID` — non-firing units like CARRYALL, HARVESTER).

### 5.1 `Tile_MoveByDirection` helper

New `Pos32.moved(by orientation: UInt8, distance: Int32)` that ports `Tile_MoveByDirection` (`src/tile.c:215`). Only used by CreateBullet in this slice; the pathfinder steps by packed-tile offsets, not this.

## 6. `Script_Unit_Fire` (slot 0x08)

Port of `src/script/unit.c:577`. Factory shape:

```swift
public static func makeFireUnit(host: Host) -> VM.Function
```

Pseudocode:

```
if !currentUnit: return 0
target = currentUnit.targetAttack
if target == 0 || !isValid(target): return 0

// A unit pointing at its own tile self-clears (sandworm exception).
ownPacked = packedTile(currentUnit.position)
if type != SANDWORM && target == EncodedIndex.tile(packed: ownPacked).raw:
    currentUnit.targetAttack = 0

if currentUnit.targetAttack != target:
    // target slot was freed between decisions; redirect.
    currentUnit.targetAttack = target
    return 0

if currentUnit.fireDelay != 0: return 0

distance = distance(currentUnit.position, positionOf(target))
if (ui.fireDistance << 8) < distance: return 0

// Orientation gate (skip for wingers + sandworm-vs-anything).
if type != SANDWORM && (target-is-not-winger):
    orientation = direction(currentUnit.position, tileOf(target))
    diff = |currentUnit.orientationCurrent - orientation|    // treat as Int16
    if ui.movementType == winger: diff /= 8
    if diff >= 8: return 0

damage = ui.damage
typeID = ui.bulletType
fireTwice = ui.firesTwice && hitpoints > maxHP/2

// Long-range trooper substitution.
if (type == TROOPERS || type == TROOPER) && distance > 512:
    typeID = UNIT_MISSILE_TROOPER

switch typeID:
  .sandworm:
    // eat — deferred; return 0 for this slice.
  .bullet / .sonicBlast / .missile_*:
    bulletIndex = createBullet(...)
    if bulletIndex == nil: return 0
    bullet.originEncoded = EncodedIndex.unit(shooter.index).raw
  .none:
    return 0  // no bullet type (carryall, harvester)

// Cooldown reset.
currentUnit.fireDelay = ui.fireDelay * 2            // game-speed scaling deferred

// firesTwice flip.
if fireTwice:
    currentUnit.fireTwiceFlip = !currentUnit.fireTwiceFlip
    if currentUnit.fireTwiceFlip: currentUnit.fireDelay = 5
else:
    currentUnit.fireTwiceFlip = false

return 1
```

### 6.1 Deferrals for this slice

The "no bullet yet but shooter burned its delay" case from OpenDUNE that's deferred here:

- **Sandworm eat** — needs `Unit_Remove` for the eaten unit plus `Map_MakeExplosion` on the worm's tile. Both deferred to the explosion-pool slice. For now the sandworm branch returns 0 without eating.
- **`Tools_AdjustToGameSpeed`** — game speed is 1.0 for now; the call is the identity. We store the raw `ui.fireDelay * 2` (matches normal speed).
- **`Tools_Random_256() & 1`** fireDelay jitter — deferred; fires always land on exact cooldown until we stream the RNG through.
- **`Unit_Deviation_Decrease`** — deviator deterioration; deferred with the deviator state.
- **`Voice_PlayAtTile(ui.bulletSound)`** — audio sink; deferred.
- **`Unit_UpdateMap(2, u)`** — fog / dirty-rect propagation; deferred until fog lands.

### 6.2 Scheduler coupling

`Scheduler.tick()` already decrements `engine.delay` and runs opcodes. For `fireDelay` to count down at tick rate (matching OpenDUNE's `Unit_Tick`), we need a new scheduler pre-pass: decrement every unit's `fireDelay` by 1 if it's non-zero. This is a tiny per-tick pass; goes in `Scheduler.tick()` before the EMC dispatch.

## 7. Testing

Coverage for this slice:

1. `UnitPool.allocateForType` per-range walk:
   - TANK → first free slot in 22..101.
   - BULLET → first free slot in 12..15.
   - Full 12..15 with 4 bullets → `nil`.
   - Out-of-range type (42) → `nil`.
2. `createBullet` with an invalid target → `nil` (returns without allocating).
3. `createBullet BULLET` → allocated slot in 12..15, orientation = direction(shooter→target), position offset by the two MoveByDirection calls, hitpoints = damage, `targetAttack` = encoded target, `currentDestination = targetTile`.
4. `createBullet MISSILE_ROCKET` → slot in 12..15 with correct orientation, `fireDelay = ui.fireDistance & 0xFF`.
5. `Script_Unit_Fire` on a unit with `fireDelay > 0` → returns 0, no bullet allocated.
6. `Script_Unit_Fire` on a unit with no target → returns 0.
7. `Script_Unit_Fire` on an out-of-range target → returns 0.
8. `Script_Unit_Fire` on an off-orientation target → returns 0.
9. `Script_Unit_Fire` success: allocates bullet in 12..15, stamps `shooter.fireDelay = ui.fireDelay * 2`, sets bullet's `originEncoded = EncodedIndex.unit(shooter.index)`.
10. `Script_Unit_Fire` firesTwice: first fire flips the flag and sets `fireDelay = 5`; second fire un-flips and sets the full reload.
11. `Scheduler.tick()` decrements `fireDelay` each call.
