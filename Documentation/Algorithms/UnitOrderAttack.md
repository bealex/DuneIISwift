# Unit attack orders (right-click on enemy)

Slice 2 of the unit-command bridge. Builds on `UnitSelectionAndOrders.md` (slice 1, move orders). Lets the player right-click an enemy unit on the map to issue an attack order.

## Goal

After this slice lands the player can:

1. Select a friendly unit (left-click) — already works (slice 1).
2. Right-click an **enemy** unit on the map → selected unit attacks it.
3. Right-click an **empty / friendly** tile → existing move-order behaviour (slice 1) is unchanged.

Deferred:

- Attack orders on enemy structures. Same scheme would work (`EncodedIndex.structure(_)`), but adds another tile-occupant lookup branch; we keep this slice tight to enemy units.
- Right-click on enemy-occupied **structure** tile — same reason.
- Voice "attacking" cue + target blink (`target->blinkCounter = 8` from `viewport.c:178`).
- The `Unit_FindTargetAround` snap-to-nearest-enemy pass — we already have a precise enemy under the click; no need for the search.
- Attack-on-tile (an "attack ground" order) — Dune II's input model doesn't support this; players target an enemy, not a square.
- Group-attack orders (drag-rect deferred since slice 1).

## Reference

`viewport.c:140..193` (`Viewport_Click` `SELECTIONTYPE_TARGET` branch) is the reference path:

```c
u->targetAttack = 0;
u->targetMove   = 0;
u->route[0]     = 0xFF;
encoded = Tools_Index_Encode(Unit_FindTargetAround(packed), IT_TILE);
Unit_SetAction(u, ACTION_ATTACK);          /* switchType=0 → reset script + Script_Load */
Unit_SetTarget(u, encoded);
//   Unit_SetTarget upgrades IT_TILE → IT_UNIT/IT_STRUCTURE if a unit/structure
//   sits on the tile, then writes targetAttack. Non-turret units also get
//   targetMove + route[0]=0xFF so the chassis drives toward the target.
target = Tools_Index_GetUnit(u->targetAttack);
if (target != NULL) target->blinkCounter = 8;
```

`Unit_SetAction` for ACTION_ATTACK (switchType `0`, see `actioninfo.c:14`) follows the same script-reset path as `ACTION_MOVE` did in slice 1. The scheduler's per-slot `loadedUnitAction != actionID` check (`Scheduler.swift:317`) reloads the engine at the next tick — same shortcut we used for MOVE.

`Unit_SetTarget` (`unit.c:1131`):

```c
if (Tools_Index_GetType(encoded) == IT_TILE) {
    /* upgrade tile → unit/structure if occupied */
}
if (Tools_Index_Encode(unit->o.index, IT_UNIT) == encoded) {
    /* attacking yourself? fall back to attacking your tile */
}
unit->targetAttack = encoded;
if (!hasTurret) {
    unit->targetMove = encoded;
    unit->route[0]   = 0xFF;
}
```

The `targetMove = targetAttack` write for non-turret units is the bit that lets foot/trike chassis drive toward the target while turreted tanks stand still and rotate. We honour both arms.

## Architecture

Same shape as slice 1: pure-state controller mutation that the scene applies. No script round-trip yet — we write `targetAttack` + `actionID` directly on the slot.

### Simulation: `Simulation.Units.orderAttack`

New function in the existing `Simulation.Units` namespace:

```swift
@discardableResult
public static func orderAttack(
    poolIndex: Int,
    targetUnitIndex: Int,
    units: inout UnitPool
) -> Bool
```

Behaviour:

1. Guard `poolIndex` and `targetUnitIndex` are in range, both slots are `isUsed`, and `targetUnitIndex != poolIndex` (no self-attack).
2. Look up `UnitInfo` for the attacker `type`. If lookup fails, return `false`.
3. Encode the target as `EncodedIndex.unit(UInt16(targetUnitIndex)).raw`.
4. Write `slot.targetAttack = encoded`, `slot.actionID = ActionID.attack` (= 0).
5. If the attacker has **no** turret (`UnitInfo.hasTurret == false`), also set `slot.targetMove = encoded`, zero `slot.currentDestination{X,Y}`, set `slot.route[0] = 0xFF` so the route follower picks up the chase next tick.
6. If the attacker **has** a turret, leave `targetMove` alone (turreted units don't reposition for attack).
7. Log the order.
8. Return `true` on success, `false` on any guard failure (pool untouched).

Deferred vs OpenDUNE:

- `Object_Script_Variable4_Clear` — we don't track linkedID-style script variable 4 separately yet.
- `target->blinkCounter = 8` — visual-only cue. Not wired in this slice.
- Voice cue (`Sound_StartSound(g_table_actionInfo[ACTION_ATTACK].soundID)`).
- `Unit_SetTarget`'s tile→unit upgrade. The controller already resolves to a unit, so we encode `IT_UNIT` directly; no upgrade path is exercised.
- `Unit_FindTargetAround` snap radius — we attack the unit the user clicked, not its neighbours.

### Controller: extend `UnitCommandController`

Add a new action case + extend the `rightMapTile` handler to discriminate between empty / friendly / enemy under the click:

```swift
public enum Action {
    case none
    case selectUnit(poolIndex: Int)
    case deselect
    case orderMove(poolIndex: Int, tileX: Int, tileY: Int)
    case orderAttack(attackerIndex: Int, targetIndex: Int)   // NEW
}
```

`handle(click: .rightMapTile, ...)` now:

1. Stale-selection auto-clear (existing).
2. If `selectedUnitIndex == nil` → `.none` (existing).
3. Scan the pool for an enemy unit whose tile equals the clicked tile (mirrors the friendly scan; just inverted on `houseID == playerHouseID`). If found and the target index ≠ the attacker index → return `.orderAttack(attackerIndex: sel, targetIndex: enemy)`.
4. Otherwise → existing `.orderMove(...)` path.

Friendly under the click on right-click: deferred. OpenDUNE collapses this to "no-op" in `SELECTIONTYPE_TARGET` (the action panel filters by selectionType); we keep the slice 1 behaviour and treat the friendly tile as a regular move target. Tested explicitly so the behaviour doesn't drift.

Same-tile-as-attacker on right-click (target == attacker tile, no enemy): falls through to `.orderMove` against the attacker's current tile, which `orderMove` already turns into a no-op via `currentDestination` zeroing — there's nothing to test here beyond the existing slice-1 test.

## Tests

`UnitOrderAttackTests.swift` (pure-sim, synthetic pool):

- Happy path, **non-turret** attacker (TROOPER, hasTurret=false): `targetAttack` set, `actionID == 0`, `targetMove == targetAttack`, `route[0] == 0xFF`, `currentDestination{X,Y} == 0`.
- Happy path, **turret** attacker (TANK, hasTurret=true): `targetAttack` set, `actionID == 0`, `targetMove` unchanged, `route` and `currentDestination` untouched.
- Attacker slot unallocated → `false`, pool untouched.
- Target slot unallocated → `false`, pool untouched.
- Self-attack (`poolIndex == targetUnitIndex`) → `false`, pool untouched.
- Out-of-range attacker / target → `false`, pool untouched.
- Overwriting an existing attack order (same attacker, different target) → fields update verbatim.

`UnitCommandControllerTests.swift` (extension to existing tests):

- Right-click over an enemy unit's tile, with a friendly selected → `.orderAttack(attackerIndex: sel, targetIndex: enemy)`.
- Right-click over an enemy tile with **nothing** selected → `.none` (no surprise rebound to attack).
- Right-click over a friendly unit's tile with another friendly selected → `.orderMove(poolIndex: sel, tileX: x, tileY: y)` (slice 1 behaviour preserved; right-click on friendly is treated as ground-move under that friendly's tile).
- Right-click over an empty tile with a friendly selected → `.orderMove` (slice 1 behaviour preserved; regression guard).
- Right-click over the attacker's own tile (no enemy on it) → `.orderMove` against own tile (existing slice-1 fallthrough behaviour).

Zero install-gated tests for this slice.

## Scene wiring

`ScenarioScene.applyCommandAction(_:)` gains the new case:

```swift
case .orderAttack(let attackerIndex, let targetIndex):
    var pool = world.units
    Simulation.Units.orderAttack(
        poolIndex: attackerIndex,
        targetUnitIndex: targetIndex,
        units: &pool
    )
    world.units = pool
```

No new visuals in this slice — the existing per-tick sim-to-visual sync handles bullet spawn / explosion / death. Selection halo still tracks the attacker.

## Manual verification checklist

`swift run duneii`, mission-1 Atreides:

1. Click a friendly unit (e.g. quad / trike) → halo appears.
2. Right-click an enemy unit ~5 tiles away.
3. Within ~1 second a log line `orderAttack u<N> → target=<M>` should appear.
4. Non-turret attacker (foot trooper, trike, quad): the attacker drives toward the enemy, then opens fire when in range.
5. Turret attacker (TANK, SIEGE_TANK): the attacker stays put, rotates the turret toward the enemy, then fires.
6. Existing right-click-on-empty-tile move order still works (regression guard).
7. Existing build panel + yard switching still work.

## File inventory

New:

- `Code/Core/Tests/DuneIICoreTests/UnitOrderAttackTests.swift`

Modified:

- `Code/Core/Sources/DuneIICore/Simulation/Units.swift` — add `orderAttack`.
- `Code/Core/Sources/DuneIIRendering/Scene/UnitCommandController.swift` — extend `Action` enum + `handle(click:)` for the enemy-tile branch.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — `applyCommandAction` gets a new case.
- `Code/Core/Tests/DuneIICoreTests/UnitCommandControllerTests.swift` — new cases for the right-click-attack branch + regression guards.

## Acceptance

- New + extended tests green.
- Full suite green with zero warnings on a clean build.
- Manual verification per the checklist.
- History entry + `CurrentState.md` bump.
