# Unit selection + move orders

Design for the first input-layer slice that turns built units from decorative pool entries into player-commandable pieces. Matches item #6 in `Documentation/WhatToDo.md`; called out as the #2 remaining gameplay hole in `CurrentState.md`.

## Goal

After this slice lands the player can:

1. Left-click a friendly unit on the map → that unit is selected (green halo).
2. Left-click a different unit → selection moves to that unit.
3. Left-click empty terrain → selection clears.
4. Right-click a walkable tile with a unit selected → the unit starts walking there.
5. Right-click a tile while *no* unit is selected → nothing.

Deferred (not in this slice):

- Drag-rectangle group selection.
- Shift-click additive selection.
- Right-click on an enemy → attack order (needs the `ACTION_ATTACK` path).
- Right-click on spice → harvest order (needs refinery return logic).
- Selection persistence across tile-count changes / unit death.
- Keyboard shortcuts.

Why so narrow: the build-panel slices proved that a small, testable controller that sits between `mouseDown` and the pool is the right pattern. Selection gets the same treatment. We extend once the single-unit move path is visibly working.

## Reference

OpenDUNE's player-input path is `gui/gui.c:GUI_Widget_ActionPanel_Click` → `Unit_Select(u)` (writes `g_unitSelected`) → action button → `Unit_SetAction(ACTION_MOVE)` → `Script_Reset` + `Script_Load(actionsPlayer[i])` + `targetMove`/`targetAttack` seeding. The actual move then runs through the unit script via `Script_Unit_SetDestination` (slot 0x05) + `Script_Unit_MoveToTarget` (slot 0x16).

We already have the *sim* side wired (`Functions.swift:686` SetDestination, `Functions.swift:793` MoveToTargetUnit, `Scheduler.swift:146` `targetMove`-driven follower, `Pathfinder_Connect` in `Simulation/Pathfinder.swift`). What's missing is the UI → sim bridge.

For this slice we **bypass the script round-trip** and write `targetMove` + `actionID` directly on the slot. Rationale: `Script_Unit_SetDestination`'s side effects (voice + fog reveal) belong in a later P5 polish pass; the scheduler's movement tick already closes on `targetMove` regardless of how it was set. When we wire `Unit_SetAction` fully we'll convert the direct write into a proper script kick.

## Architecture

Mirror the `BuildPanelController` shape. A new pure-state controller, `UnitCommandController`, owns:

- `selectedUnitIndex: Int?` — pool slot of the currently-selected friendly unit, or `nil`.

Two click entry points, symmetric with the build panel:

```swift
enum Click {
    case leftMapTile(x: Int, y: Int)
    case rightMapTile(x: Int, y: Int)
}

enum Action {
    case selectUnit(poolIndex: Int)
    case deselect
    case orderMove(poolIndex: Int, tileX: Int, tileY: Int)
    case none
}

func handle(click: Click, pool: Simulation.UnitPool, playerHouseID: UInt8) -> Action
```

The controller is pure — it does not mutate pool state. `ScenarioScene` translates `Action` into either a selection-state update (repaint halo) or a pool mutation (`Simulation.Units.orderMove`).

## Simulation: `Simulation.Units.orderMove`

Add one new function to the existing `Simulation.Units` namespace:

```swift
public static func orderMove(
    poolIndex: Int,
    tileX: Int,
    tileY: Int,
    units: inout UnitPool
)
```

Behaviour:

1. Guard the slot is `isUsed`.
2. Compute the packed-tile encoded index (`Scripting.EncodedIndex.tile(packed:)`).
3. Write `slot.targetMove = encoded.raw` and `slot.actionID = Simulation.UnitInfo.ActionID.move` (= 1).
4. Zero `slot.route[0] = 0xFF` so the scheduler re-runs the pathfinder against the new target.
5. Zero `slot.currentDestination{X,Y}` for the same reason — forces the scheduler to consult `targetMove` on the next tick (Scheduler.swift:179).

That's it. The existing scheduler pass picks it up and closes on the tile over subsequent ticks.

## Tests (TDD-first)

All in a new `UnitCommandControllerTests.swift` + `UnitOrderMoveTests.swift` pair.

Controller (pure-sim, synthetic pool):

- Left-click over a friendly unit's tile → `.selectUnit(n)`.
- Left-click over an enemy unit's tile → `.none` (enemies not yet selectable).
- Left-click over empty terrain with nothing selected → `.none`.
- Left-click over empty terrain with a selection → `.deselect`.
- Left-click over a friendly unit while one is already selected → `.selectUnit(newIndex)` (switch).
- Right-click over a walkable tile with nothing selected → `.none`.
- Right-click over a walkable tile with a unit selected → `.orderMove(unitIndex, x, y)`.
- Right-click over the same tile the unit is standing on → `.none` (noop, not a move).
- Selected unit gets freed between selection and next click → `selectedUnitIndex` reads as stale; next click that observes `!isUsed` auto-deselects.

`orderMove` (pure-sim):

- Happy path: `targetMove` set to `EncodedIndex.tile(packedX, packedY).raw`, `actionID == 1`, `route[0] == 0xFF`, `currentDestination{X,Y} == 0`.
- Unallocated slot → noop (pool unchanged).
- Overwriting an existing `targetMove` → replaces without routing through a script (we're below the script layer).
- Integration with scheduler: run `orderMove` → tick N times → pool slot's `position{X,Y}` has moved toward the target tile (synthetic 64×64 open map via the pathfinder host closure).

Zero install-gated tests for this slice. All behaviour is pool + controller math.

## Scene wiring

`ScenarioScene.mouseDown` currently branches: yard-select, then build-panel click classification. Add a third branch **before** both:

1. If the click is on the map area and the build controller is not mid-placement, route to the unit-command controller first.
2. If the controller returns an action, apply it; `return` before reaching the build-panel logic.
3. Otherwise fall through to the existing build-panel path (so map clicks that hit yards still switch `selectedYardIndex`).

A selection halo is an `SKShapeNode` circle (radius = tile size × 0.8, `strokeColor = .green`, `lineWidth = 2`, `fillColor = .clear`) parented to the selected unit's marker. Rebuilt in `syncVisualsFromPool()` — cheap, mirrors how the progress bar gets rebuilt each tick.

Right-click on AppKit: `NSEvent.type == .rightMouseDown`, plumbed via `override func rightMouseDown(with:)`. Trackpad two-finger tap emits this on modern macs; control-click also works.

## Manual verification checklist

`swift run duneii`, mission-1 Atreides:

1. Scene loads straight into the map (no mentat intermediary — covered by the sibling change in this session).
2. Click any Atreides unit → green halo appears around it.
3. Click a different Atreides unit → halo jumps.
4. Click empty sand → halo disappears.
5. With one Atreides unit selected, right-click a sand tile ~10 tiles away → unit begins walking. Log line: `order-move unit=N tile=(X,Y)`.
6. Right-click a rock tile the unit can't reach → unit attempts, halts at nearest reachable (pathfinder behaviour; not a regression).
7. Click an enemy unit → no halo (not selectable in this slice).
8. Build panel still works — clicking a buildable row, waiting for READY, clicking to place a structure is unaffected.

## File inventory

New:

- `Code/Core/Sources/DuneIIRendering/Scene/UnitCommandController.swift`
- `Code/Core/Tests/DuneIICoreTests/UnitCommandControllerTests.swift` *(lives in Core tests even though the controller is in Rendering; mirrors `BuildPanelController`)*
- `Code/Core/Tests/DuneIICoreTests/UnitOrderMoveTests.swift`

Modified:

- `Code/Core/Sources/DuneIICore/Simulation/Units.swift` — add `orderMove`.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — wire controller + halo.

## Acceptance

- Controller + `orderMove` tests all green.
- Full suite green with zero warnings post-clean-build.
- Manual verification from the checklist above.
- History entry + one-line `CurrentState.md` bump.

## Landed 2026-04-21

Slice 1 shipped in a single session. Final shape matched the design above — no surprises. Cross-links:

- Controller: `Code/Core/Sources/DuneIIRendering/Scene/UnitCommandController.swift`.
- Pure-sim bridge: `Code/Core/Sources/DuneIICore/Simulation/Units.swift` — `orderMove(poolIndex:tileX:tileY:units:)`.
- Scene wiring: `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — `mouseDown` / `rightMouseDown` / `refreshSelectionHalo` / `validateSelectionHalo` / `applyCommandAction`.
- Controller tests: `Code/Core/Tests/DuneIICoreTests/UnitCommandControllerTests.swift` (11 cases).
- `orderMove` tests: `Code/Core/Tests/DuneIICoreTests/UnitOrderMoveTests.swift` (7 cases, incl. scheduler integration).
- Insight: `Documentation/Insights/simulation-action-id-drives-script-reload.md`.
