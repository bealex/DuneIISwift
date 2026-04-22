# EMC-driven SetSpeed for ground units

Ground units spawn with `slot.speed == 0` and, until recently, stayed there even after the player issued a MOVE or ATTACK order. The scheduler's route-follower clamps step size at `max(4, slot.speed / 4)`, so a zero-speed unit degrades to 4 px/tick (≈5 seconds per tile). The breakage is in the EMC-driven speed pipeline, not the scheduler.

## Reference

OpenDUNE sets a unit's speed during the MOVE action via this chain:

1. `Script_Unit_SetAction(ACTION_MOVE)` (`src/unit.c:497`) resets the engine and sets `variables[0] = ACTION_MOVE`.
2. The compiled MOVE handler in `UNIT.EMC` (entry via the main dispatcher at script word 1363) routes to the MOVE body at word 637.
3. The MOVE body calls `Script_Unit_GetInfo(0x0B)` — "does the unit have a `currentDestination`?" — at word 645. If yes, it sets a short delay and loops; if no, it falls through to set up the move.
4. Falling through, the handler eventually calls `Script_Unit_CalculateRoute` (`src/script/unit.c:1296`) with `targetMove` as argument.
5. `CalculateRoute`, when it consumes a route step, invokes `Unit_StartMovement` (`src/unit.c:1059`) which, at line 1105, calls `Unit_SetSpeed(unit, speed)` with `speed = g_table_landscapeInfo[landscape_type].movementSpeed[ui->movementType]` (reduced by 1/4 if HP < max/2 for non-winger units).
6. `Unit_SetSpeed` (`src/unit.c:1902`) writes the final `unit->speed` byte that the outer movement loop reads.

## The two breakages

### Breakage 1 — `GetInfo` subcase `0x0B` misport

OpenDUNE `src/script/unit.c:968`:

```c
case 0x0B: return (u->currentDestination.x == 0 && u->currentDestination.y == 0) ? 0 : 1;
```

Our port in `Scripting/Functions.swift` was reading `slot.targetMove`, which is a *different* field — `targetMove` is the ultimate goal tile the player clicked on; `currentDestination` is the pixel-level per-step goal the route-follower is walking toward right now. On tick 1 of a fresh MOVE order, `targetMove != 0` but `currentDestination == (0, 0)`. OpenDUNE returns 0 (→ script proceeds to `CalculateRoute`); our port returned 1 (→ script loops at the "already moving" wait).

Fix: check `currentDestinationX` and `currentDestinationY`. One line.

### Breakage 2 — `Unit_StartMovement`'s SetSpeed is not replicated

`Script_Unit_CalculateRoute` in OpenDUNE ends its success path by calling `Unit_StartMovement` (`unit.c:1345`). That function:

* Rotates orientation to the next route step (we already do this in our port via `orientationCurrent = route[0] * 32`).
* Looks up `landscape_speed = g_table_landscapeInfo[landscape].movementSpeed[movementType]` (`unit.c:1091`).
* Reduces the speed by 1/4 if HP < max/2 and the unit isn't a winger (`unit.c:1103`).
* Calls `Unit_SetSpeed(unit, landscape_speed)` which writes `unit->speed`.
* Memmoves the route array to consume the step.

Our port does the memmove and the orientation lock, but skips the landscape-speed SetSpeed call. That's why, even after breakage 1 is fixed and the script *does* reach CalculateRoute, `slot.speed` remains 0.

Fix: inject the landscape-speed lookup into `makeCalculateRouteUnit` at the same point OpenDUNE does. To look up the landscape type we need a host-side callback — add `Scripting.Host.landscapeAt` (packed-tile → LandscapeType raw byte). `ScenarioScene` wires it from the scenario world's tile grid. When the host doesn't supply one (headless tests), the speed-setting step is skipped — keeps existing test harnesses working.

## Simplifications we're taking

* We write `slot.speed` directly, skipping OpenDUNE's `Unit_SetSpeed` post-processing (`movingSpeedFactor` / gameSpeed adjust / speed-vs-speedPerTick split — `src/unit.c:1902`). Our scheduler's step math is already a coarse approximation (`step = max(4, slot.speed / 4)`); the full split would require a `speedPerTick` accumulator field and isn't necessary to make ground units move at a visible pace. Byte-for-byte parity with OpenDUNE's sub-pixel accumulator is queued for the tick-parity golden harness (see `CurrentState.md` "Next up" #6).
* `Unit_StartMovement` also teleports the unit to the adjacent tile, updates the map, and sets wobble/smoking flags. Our scheduler handles per-tile motion smoothly via `tickMovement` instead; we keep the per-step memmove we already had and just add the SetSpeed. The teleport-and-update behavior isn't necessary for visible correctness.
* The HP<half speed reduction IS ported — it's a one-liner and it surfaces in gameplay (damaged tanks visibly slow down).

## Tests

* `UnitGetInfoTests` — 0x0B returns 0 when `currentDestinationX==0 && currentDestinationY==0` (even when `targetMove != 0`); returns 1 when either `currentDestination` axis is non-zero.
* `UnitCalculateRouteTests` (extend existing `PathfinderTests` or add new file):
  * With a `landscapeAt` closure returning rock (LST=0 — tracked speed 112), a freshly-consumed step writes `slot.speed = 112` (assuming `byScenario == true`).
  * Same, but HP below half → `slot.speed = 112 - 112/4 = 84`.
  * Without a `landscapeAt` closure, `slot.speed` is left untouched (regression guard for install-less tests).
  * Winger unit (ORNITHOPTER) does NOT get the HP reduction even when damaged.

## Manual verification (visual)

Run `swift run duneii` at mission-1 Atreides:
1. Click a friendly unit, right-click a distant empty tile.
2. Expect the unit to visibly travel at ≈0.5-1 tiles/second on rock, slower on sand-rock, faster on smooth sand — i.e. *not* the 5-second-per-tile crawl that came before.
3. Damage the unit (right-click an enemy turret, take a few hits). At < 50% HP, movement should visibly slow.

## Cross-references

* `Scripting/Functions.swift` — `makeGetInfoUnit` (line 141), `makeCalculateRouteUnit` (line 763).
* `Scripting/Scripting.swift` — `Host` will grow `landscapeAt`.
* `Simulation/Scheduler.swift:258` — the route-follower step calc that reads `slot.speed`.
* OpenDUNE reference: `src/unit.c:1059 Unit_StartMovement`, `:1902 Unit_SetSpeed`, `src/script/unit.c:946 Script_Unit_GetInfo`, `:1296 Script_Unit_CalculateRoute`.
