# Explosions + damage

Status: Drafted 2026-04-20 (P4 Phase 4 — third slice; Fire + projectile landed).

Bullets that hit their target don't "damage" anything directly — they queue themselves for detonation, and when their EMC script calls `Script_Unit_ExplosionSingle`, `Map_MakeExplosion` runs the radius scan, applies damage to every unit within reach, and adds an entry to the 32-slot `g_explosions` pool so the renderer can animate the blast. This doc covers the port of that pipeline.

References:

- `src/map.c:403` — `Map_MakeExplosion`.
- `src/unit.c:1530` — `Unit_Damage`.
- `src/structure.c:1039` — `Structure_Damage`.
- `src/explosion.c:282` — `Explosion_Start`.
- `src/explosion.h` — `ExplosionType` enum + 32-slot pool constant.
- `src/script/unit.c:533` — `Script_Unit_ExplosionSingle` (slot 0x0E).
- `src/script/unit.c:553` — `Script_Unit_ExplosionMultiple` (slot 0x12) — deferred to a later slice (needs `Tile_MoveByRandom`).

## 1. Pool shape

`Simulation.ExplosionPool` mirrors OpenDUNE's `g_explosions[EXPLOSION_MAX=32]`. Each slot stores the minimum to drive presentation and tick-level timing — no command-stream interpreter yet, because **damage happens on `makeExplosion` entry, not during the animation**. The pool is purely for the renderer and `Map_MakeExplosion`'s "stop any in-flight explosion on this tile" dedup.

```swift
public struct ExplosionSlot: Sendable, Equatable {
    public var isActive: Bool
    public var type: UInt16           // ExplosionType raw value (0..19)
    public var positionX: UInt16
    public var positionY: UInt16
    public var houseID: UInt8         // for tinting / scoring — 0xFF = unowned
    public var remainingFrames: UInt16  // coarse tick countdown (deferred cmd stream)
}

public struct ExplosionPool: Sendable, Equatable {
    public static let capacity = 32
    public private(set) var slots: [ExplosionSlot]
    public private(set) var findArray: [Int]
    ...
}
```

Allocation strategy: first-unused-slot walk (OpenDUNE's `Explosion_Start` loops 0..31 looking for a `commands == NULL` entry). When the pool is full, new explosions are silently dropped — matches the original. Before spawning, we stop any existing explosion on the same packed tile (OpenDUNE's `Explosion_StopAtPosition`).

## 2. `Simulation.ExplosionType`

Exact mirror of OpenDUNE's `ExplosionType` enum (`src/explosion.h:13`). Raw `UInt16` keyed by the numeric IDs (0..19) so EMC `peek(1)` pull-through works unchanged. `invalid = 0xFFFF` sentinel preserved.

## 3. `applyUnitDamage(unitIndex:damage:host:)`

Simplified port of `Unit_Damage` (`src/unit.c:1530`):

1. Guard on `isAllocated` + `isNormalUnit` (only real units take damage — bullets don't).
2. Subtract damage; clamp to 0.
3. On reaching 0: free the slot. (OpenDUNE calls `Unit_SetAction(ACTION_DIE)` which triggers an EMC-driven death sequence. We short-circuit to `free` — the `explodeOnDeath` + harvester-spice-spill + trooper-to-soldier halving path is deferred.)

Returns `true` when the unit was destroyed by this call. Harvester spice spill, infantry halving, smoke, AI retaliation — all deferred.

## 4. `applyStructureDamage(structureIndex:damage:host:)`

Simplified port of `Structure_Damage`:

1. Guard on `isUsed`.
2. If `damage == 0`: return false.
3. Subtract damage; clamp to 0.
4. On reaching 0: free the slot. Deferred: score updates, `Structure_Destroy` chain (rubble spawning, credit refund, "enemy building destroyed" voice).

Returns `true` when the structure was destroyed.

## 5. `makeExplosion(type:position:hitpoints:unitOriginEncoded:host:)`

Port of `Map_MakeExplosion`. Minimal slice — radius damage + structure-at-point damage + pool entry. Deferred: AI retaliation (`Unit_SetTarget` + `ACTION_HUNT` writes on surrounding enemies), wall decay (`Map_UpdateWall`), `Structure_HouseUnderAttack`.

Algorithm:

```
reactionDistance = (type == DEATH_HAND) ? 32 : 16
if hitpoints != 0:
    for each unit in host.units:
        d = distance(position, unit.position) >> 4       // pos32 → tiles
        if d >= reactionDistance: continue
        if unit.type == SANDWORM && type == SANDWORM_SWALLOW: continue
        if unit.type == FRIGATE: continue
        damage = hitpoints >> (d >> 2)
        applyUnitDamage(unit, damage)

if hitpoints != 0:
    s = structure at packedTile(position)
    if s != nil:
        // EXPLOSION_IMPACT_LARGE downgrades to SMOKE_PLUME when the
        // building is already below half HP (original cosmetic rule).
        if type == IMPACT_LARGE:
            if info.hitpoints / 2 > s.hitpoints:
                type = SMOKE_PLUME
        applyStructureDamage(s, hitpoints)

explosionPool.add(type: type, position: position, houseID: ...)
```

## 6. `makeExplosionSingleUnit` (slot 0x0E)

Thin wrapper:

```swift
peek(1) = explosion type
host.makeExplosion(
    type: peek(1),
    position: currentUnit.position,
    hitpoints: UnitInfo[currentUnit.type].hitpoints,   // maxHP as the AoE damage
    unitOriginEncoded: EncodedIndex.unit(currentUnit.index)
)
return 0
```

The `hitpoints` argument is the unit's **max** HP, not its current HP — matches OpenDUNE. Nobody uses the returned encoded index since `Script_Unit_ExplosionSingle` always returns 0.

## 7. What this does NOT cover

- `Script_Unit_ExplosionMultiple` (slot 0x12) — needs `Tile_MoveByRandom`. Port when DEVASTATOR or DEATH_HAND missile actually matters.
- Explosion command-stream interpreter (`g_table_explosion[type]` + 10-opcode `ExplosionCommand` switch) — this is animation, presentation layer. The `ExplosionPool.tick()` equivalent is a placeholder `remainingFrames` counter decrementing to 0, and the renderer reads `type` to pick a sprite.
- `explodeOnDeath` + `ACTION_DIE` EMC state — tanks don't "tank explode" yet; they just disappear. Wire when we port the full `Unit_Damage` with action changes.
- `ornithopter crash` / `carryall crash` — needs the winger tick handler.
- `Unit_SetTarget` AI retaliation — needs team/action state.
- Wall decay + `Map_UpdateWall`.

## 8. Testing

- `ExplosionPool.add` wraps when pool is full (returns `nil`).
- `ExplosionPool.stopAtPosition` clears an in-progress entry at a packed tile.
- `applyUnitDamage` reduces HP; returns true on zero and frees the slot.
- `applyUnitDamage` on a bullet (non-NormalUnit) returns false.
- `applyStructureDamage` reduces HP; returns true on zero and frees the slot.
- `makeExplosion` with 0 hitpoints skips damage but still queues the pool entry.
- `makeExplosion` radius damage: unit at d=0 takes full HP, unit at d=1 takes half, unit outside reactionDistance takes none.
- `makeExplosion` DEATH_HAND reaches twice as far (32 tiles vs 16).
- `makeExplosion` sandworm + SANDWORM_SWALLOW combo → sandworm unharmed.
- `makeExplosion` structure-at-point damage.
- Slot 0x0E `ExplosionSingle`: calls `makeExplosion` with peek(1) type, unit.position, unit.info.hitpoints, `EncodedIndex.unit(index)`.
