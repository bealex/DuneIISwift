# Unit firing & projectile spawn

How a unit shoots: the `Script_Unit_Fire` native (op `0x08`) and the spawn primitives it composes. Faithful transcription of OpenDUNE `src/script/unit.c:577` (`Script_Unit_Fire`), `src/unit.c:1380` (`Unit_Create`), `src/unit.c:1310` (`Unit_CreateBullet`), `src/unit.c:1789` (`Unit_IsTileOccupied`). Ours: `DuneIISimulation/UnitCombat.swift`.

## `Script_Unit_Fire` (UnitCombat.fire) — control flow

Returns 1 if a shot was fired, 0 otherwise. The early-outs, in order:

1. No / invalid `targetAttack` → 0.
2. Self-target (non-sandworm, target == own tile index) → clear `targetAttack`.
3. `targetAttack` changed since entry → `Unit_SetTarget` and bail (0).
4. Still turning the aiming part (`orientation[hasTurret ? 1 : 0].speed != 0`, non-sandworm) → 0.
5. Target tile now holds an object → `Unit_SetTarget` (retarget to it).
6. `fireDelay != 0` (reloading) → 0.
7. `Object_GetDistanceToEncoded` to target `> fireDistance << 8` (signed) → 0.
8. Aim off by ≥ 8 of 256 (non-sandworm; winger divides the diff by 8) → 0.

Then it picks `damage = ui.damage`, `typeID = ui.bulletType`, computes `fireTwice` (`firesTwice` flag && hp > maxHP/2), promotes a long-range trooper shot to `MISSILE_TROOPER`, and:

- **sandworm bulletType** → devour: `Unit_UpdateMap(0)`, remove the target unit, `Map_MakeExplosion` (SEAM), `Unit_UpdateMap(1)`, `amount--`, `delay = 12`, `ACTION_DIE` when out of bites.
- **bullet / sonic / missile bulletType** → `Unit_CreateBullet`, stamp the bullet's `originEncoded` to the firer, `Unit_Deviation_Decrease(20)`.

Post-fire: `fireDelay = Tools_AdjustToGameSpeed(fireDelay*2, 1, 0xFFFF, inverse)`; the `firesTwice` 2nd shot uses a short `AdjustToGameSpeed(5,1,10,inverse)` delay (tracked by the `fireTwiceFlip` flag); `fireDelay += Tools_Random_256() & 1`; `Unit_UpdateMap(2)`.

## `Unit_CreateBullet` — projectile spawn

`if !valid(target) return nil`. Two shapes:

- **MISSILE_* (rocket/turret/deviator/trooper/house):** spawn at the firing tile facing the target; `targetAttack = target`, `hitpoints = damage`, `currentDestination = targetTile`; `notAccurate` bullets scatter the destination (`Tile_MoveByRandom`, drawing RNG); `fireDelay = fireDistance & 0xFF` (doubled vs a winger target).
- **BULLET / SONIC_BLAST:** spawn **one tile ahead** along the line of fire (`MoveByDirection(MoveByDirection(pos,0,32), orient, 128)`); `currentDestination = targetTile`, `hitpoints = damage`, `bulletIsBig` when `damage > 15`.

Both: if the bullet isn't already player-visible, `Tile_RemoveFogInRadius(pos, 2)`. (`Voice_PlayAtTile` is an audio SEAM.)

## `Unit_Create` — general spawn

`Unit_Allocate` → set orientation (both levels, instant) + speed 0 → position/hitpoints/route/destination init → `Unit_FindClosestRefinery` (whose return *overwrites* `originEncoded`, a faithful OpenDUNE quirk) → reset the script, set `allocated`. Tracked units roll `degradingChance` for the `degrades` flag (one `Random256` draw). Wingers get speed 255; ground units bail (free + nil) if `Unit_IsTileOccupied`. An off-map (`0xFFFF:0xFFFF`) position yields an `isNotOnMap` unit; otherwise `Unit_UpdateMap(1)` + `Unit_SetAction(default)`.

## Verification

- **Golden:** `ScenarioGoldenTests` `attack-close` — the attacker fires at tick 61 and the spawned bullet (unit 12, type 23, hp 25, orient 64 @ packed 1040) matches the oracle bit-for-bit, then flies identically through tick 66. (Diverges at tick 67 = the bullet's impact damage — see the `Unit_Move` bullet branch SEAM, step 2c.)
- **Unit:** `UnitCombatTests` — `unitCreate` (winger placed / off-map), `unitCreateBullet` (facing/damage/big), `fire` early-outs.

## Seams (open)

- `Map_MakeExplosion` (#15) — the bullet's arrival explosion (→ `Unit_Damage`/`Structure_Damage`) and the sandworm/saboteur blasts. **This is step 2c** and is what extends `attack-close` past tick 66.
- `Voice_PlayAtTile` (bullet/fire sounds) — audio.
