# Unit movement cluster (Tier D′/F)

How a ground unit actually crosses the map, end-to-end. Ported from OpenDUNE `src/unit.c`, `src/script/unit.c`, `src/tile.c`. This is the chain that turns a `targetMove` (set by a player order) into a per-tick change of `position`, verified against the committed `moving-golden.jsonl` oracle trajectory.

## The chain

A player order (`UnitOrders.order`, `gui/viewport.c`) sets `actionID = MOVE`, loads the unit's EMC script, and sets `targetMove` (`Unit_SetDestination`). From there the script + the game loop drive movement:

1. **`GameLoop_Unit`** (`unit.c:123`) runs every tick. It computes which sub-activities are due (movement every 3 game-ticks, rotation on a gameSpeed cadence, script every 5), then per unit (in `Unit_Find` order): aims the turret, runs `Unit_MovementTick`, `Unit_Rotate`, the script, and finally promotes a queued `nextActionID`.

2. **The MOVE script routine** (UNIT.EMC) loops calling **`Script_Unit_CalculateRoute`** (native `0x0C`) toward `targetMove`, with `General_Delay`s between. CalculateRoute:
   - returns 1 immediately if the unit already has a `currentDestination` (a waypoint in progress) or the target is invalid;
   - if `route[0] == 0xFF` (no route yet) runs **`Script_Unit_Pathfinder`** (already ported, `Pathfinder.swift`) src→dst and copies up to 14 steps into `route[]`;
   - else trims the route to the remaining straight-line distance;
   - if the unit isn't yet facing `route[0] * 32`, turns it (`Unit_SetOrientation`, non-instant) and returns 1 — **one route step per "face then step"**;
   - otherwise calls **`Unit_StartMovement`**; on success shifts `route[]` left by one and returns 1.

3. **`Unit_StartMovement`** (`unit.c:1059`) commits to the next tile: snaps `orientation[0]` to the nearest 8-dir (`(current + 16) & 0xE0`), steps one whole tile with **`Tile_MoveByOrientation`** to get `position`, checks **`Unit_GetTileEnterScore`** (already ported) — bails if blocked (`> 255` or `-1`) — derives `speed` from the landscape's `movementSpeed[movementType]`, calls `Unit_SetSpeed`, claims the destination tile (`Unit_UpdateMap(1)` at the temp position), sets `currentDestination = position`, and `Unit_Deviation_Decrease(10)`. It does **not** move `o.position`; it sets the *target* the per-tick mover walks to.

4. **`Unit_MovementTick`** (`unit.c:98`) runs on the movement cadence: accumulates `speedRemainder += AdjustToGameSpeed(speedPerTick)`; on a byte carry calls **`Unit_Move`** with `min(speed*16, dist(position, currentDestination) + 16)`.

5. **`Unit_Move`** (`unit.c:1286`) is the sub-tile step. It moves `position` by `distance` sub-units along `orientation[0].current` (`Tile_MoveByDirection`), reconciles the map (`Unit_UpdateMap(0)` before, `(1)` after), and — when the step reaches/overshoots `currentDestination` (`distanceToDestination < distance || distance < 16`) for a ground unit — snaps onto the waypoint, records `targetLast`/`targetPreLast`, **clears `currentDestination`**, `Unit_SetSpeed(0)`, and clears `targetMove` once it equals the arrived tile. Clearing `currentDestination` is what lets the next script tick's CalculateRoute commit the following route step.

So the loop is: CalculateRoute faces + StartMovement commits one tile → MovementTick/Move walks the unit there over several movement ticks → arrival clears `currentDestination` → next CalculateRoute commits the next tile. Repeat until `route[0] == 0xFF` and `targetMove` is cleared.

## Seams (branches transcribed but inert for the ground-unit-on-sand path)

`Unit_Move` carries the bullet / sonic-blast / saboteur / spice-bloom / structure-entry branches verbatim. Their not-yet-ported dependencies are marked `SEAM` in code and never fire for a tank crossing open sand:

- `Unit_Damage` (#18), `Map_MakeExplosion` (#15), `Map_DeviateArea`, `Map_Bloom_Explode*` — combat/explosion, Tier E / map.
- `Unit_EnterStructure` — arrival onto a structure tile.
- `Animation_Start` for tracks, `Unit_Select(NULL)` — render seams.
- The driving-over-a-foot-unit branch sets the *other* unit's `ACTION_DIE` via the standalone `Unit_SetAction` (no engine threading; that unit's own `o.script` is the target).

`Unit_Deviation_Decrease` returns immediately for a non-deviated unit; the expiry branch (re-`SetAction` + untarget) is reached only by deviated units. Because `Unit_StartMovement` runs inside a script execution, the engine is threaded into `deviationDecrease` so an expiry mid-route-calc targets the live engine copy.

## Verification

`Tile_MoveByOrientation` has a direct unit test (the eight direction vectors + the out-of-map clamp) and is bit-verified end-to-end through `Unit_StartMovement` by the trajectory golden. The whole cluster is verified behaviourally by `ScenarioGoldenTests.moving`: both engines load `bootstrap.ini`, issue MOVE to tile 2600, and run per-tick; ours must equal the oracle's committed 400-tick trajectory (`moving-golden.jsonl`) tile-for-tile and orientation-for-orientation. This is the Tier-2 integrated check for the movement natives — the gate that raises `comparedTicks` past 1.
