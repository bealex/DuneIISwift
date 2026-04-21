# Build panel — UI wiring for `Structure_GetBuildable` + `Structure_Create`

Status: Drafted 2026-04-21 (P5 slice 3 — first user-visible slice).

Slice 1 produced the buildable bitmask. Slice 2 produced the allocator. Slice 3 surfaces both to the mouse: a sidebar on `ScenarioScene` lists every buildable type for the currently-selected construction yard; clicking a slot enters placement mode; clicking a map tile commits the placement via `Simulation.Structures.create(...)`.

This slice deliberately leaves several OpenDUNE behaviours unimplemented (see §6). The goal is an end-to-end loop — bitmask → list → click → allocate — the user can *see*. Valid-location gating, countdown, credit drain, and ghost preview all come with slice 4.

References:

- `Documentation/Algorithms/StructureBuildable.md` — slice 1 data layer.
- `Documentation/Algorithms/StructureCreate.md` — slice 2 allocator.
- OpenDUNE `src/gui/widget.c` + `src/gui_draw.c` — the factory-window rendering; we do *not* port the pixel-accurate layout yet.

## 1. Architecture split

Two pure types + one thin scene extension:

- `Simulation.StructureInfo.buildableTypes(from: UInt32) -> [UInt8]` — decodes the slice-1 bitmask into an ordered type-ID list. Order is ascending type ID for now (OpenDUNE sorts by `sortPriority` — deferred; see §6).
- `DuneIIRendering.BuildPanelController` (new file) — pure state machine. Holds `selectedYardIndex: Int?`, `placementType: UInt8?`, and the latest `availableTypes: [UInt8]`. Takes `Click` values, returns `Action` values. No SpriteKit imports. Testable.
- `ScenarioScene` (existing, extended) — owns a `BuildPanelController`, renders the sidebar, translates `NSEvent` → `Click`, responds to `Action`.

Keeping the state machine pure is the leverage point: sidebar rendering is untestable from the sandbox, but the transition table is fully pinnable.

## 2. Scene size

The map is 64×64 tiles at 16 pt each = 1024 pt wide. The sidebar adds 128 pt on the right (8 tiles). New total: **1152 × 1024**. The scene's `anchorPoint` stays at `.zero` (bottom-left). Sidebar sits at `x >= 1024`.

## 3. `BuildPanelController` state transitions

```
states: Empty, SlotSelected, Placing

events:
  .sidebarSlot(i)     — i is a row index into availableTypes
  .mapTile(x, y)      — grid coordinates 0..<64
  .outside            — click elsewhere (e.g. banner, ambient space)

Empty --sidebarSlot(i)--> Placing(type=availableTypes[i])
Empty --mapTile/outside--> Empty (no-op from controller; scene may route elsewhere)

Placing --mapTile(x,y)--> Empty, emitting .commitPlacement(type, x, y)
Placing --sidebarSlot(i)--> Placing(type=availableTypes[i])  — re-pick
Placing --outside--> Placing (no-op; cancel is slice 4)
```

The `Action` enum returned by `handle(click:)`:

- `.none` — controller consumed the click but there's nothing for the scene to do (re-pick, or click outside).
- `.enterPlacement(type: UInt8)` — scene should render a placement cursor.
- `.commitPlacement(type: UInt8, tileX: Int, tileY: Int)` — scene should call `Simulation.Structures.create(...)` with the tile's pos32.

The scene keeps the controller up-to-date by calling `refreshAvailableTypes(_:)` after each commit (slice 1's bitmask changes once a structure lands).

## 4. Sidebar rendering

One sprite per element of `availableTypes`, stacked vertically from the top of the sidebar. Each sprite:

- Width = `sidebarWidth - 2 * inset`; height = `rowHeight` (both tunable; starting values 104 pt × 32 pt).
- Texture: resolved from `Formats.IconMap` via `Simulation.StructureInfo.iconGroupRawValue(for:)` (slice 1 already exposes this) and `AssetLoader.loadIcn()`. Uses the first tile of the iconGroup — which is the "finished-construction" tile — to keep things readable.
- `zPosition = 10` so it sits above the map.
- A 1pt outline (`SKShapeNode`) around each sprite to separate slots.

When `placementType != nil`, the row for that type gets a brighter outline (slice 3 lower-fidelity than slice 4's ghost preview, but user sees a selection state).

## 5. Click translation

`ScenarioScene.mouseDown(with:)`:

```swift
let location = event.location(in: self)
let click: Click
if location.x >= mapWidth {
    let slot = controller.sidebarSlotIndex(atY: location.y)  // or nil
    click = slot.map { .sidebarSlot(index: $0) } ?? .outside
} else {
    let tileX = Int(location.x / tileSize)
    let tileY = 63 - Int(location.y / tileSize)
    click = .mapTile(x: tileX, y: tileY)
}
switch controller.handle(click: click) {
case .enterPlacement(let type): /* update visuals */
case .commitPlacement(let type, let x, let y):
    let pos = Pos32(x: UInt16(x * 256), y: UInt16(y * 256))
    _ = Simulation.Structures.create(
        type: type, houseID: playerHouseID, position: pos, pool: &host.structures
    )
    refreshSidebar()
case .none:
    if !isPlacing && !clickedSidebar { coordinator?.route(to: .mainMenu) }
}
```

The "click outside, not placing, not sidebar → return to menu" fallback preserves the existing scene behaviour and lets the user escape without a keyboard shortcut. Slice 4 can add Escape-key cancel.

## 6. What slice 3 does NOT cover

- **Yard selection** — the scene auto-picks the player's first construction yard on load. Clicking a different yard to switch is slice 4.
- **Sort order** — OpenDUNE sorts by `StructureInfo.sortPriority`. Slice 3 uses ascending type-ID order (so WINDTRAP (9) sits below PALACE (2)). Visually ok for mission 1 since only 3 options appear; slice 4 ports `sortPriority`.
- **Valid-location gating** — `Structure_IsValidBuildLocation` deferred. A click on any tile commits; overlapping placements are possible.
- **Countdown + credit drain** — instant placement. Slice 4.
- **Ghost preview at cursor** — no hovering footprint. Slice 4.
- **In-game ICN tile stamping** — `ScenarioWorld` stamps footprint tiles at scene load; live `Structures.create` updates `positionX/Y` but doesn't repaint the tile grid. The new structure shows as the existing outline-rectangle marker (slice 2 flow). Slice 4 extracts the stamp code into a reusable helper.
- **Escape / right-click cancel** — no keyboard or secondary-click handling. Slice 4.
- **Building options not yet unlocked** — a click on an empty sidebar row (below the last type) does nothing.

## 7. Testing

Two pure-function suites:

### `StructureInfo.buildableTypes`

- Empty bitmask → empty array.
- `(1 << WINDTRAP)` → `[9]`.
- `(1 << SLAB_1x1) | (1 << WINDTRAP) | (1 << REFINERY)` → `[0, 9, 12]` (ascending type-ID).
- `0xFFFF_FFFF` → all 19 type IDs (every bit in range).
- Ignores bits 19..31 (only 0..18 are valid structure types).

### `BuildPanelController`

- Initial state: `selectedYardIndex == nil`, `placementType == nil`, `availableTypes == []`.
- `refreshAvailableTypes([9, 0])` + `handle(.sidebarSlot(0))` → `.enterPlacement(type: 9)`.
- `handle(.sidebarSlot(99))` (out-of-range) → `.none` and state unchanged.
- After `.enterPlacement(type: 9)`, `handle(.mapTile(x: 5, y: 5))` → `.commitPlacement(type: 9, tileX: 5, tileY: 5)` and `placementType` returns to `nil`.
- After `.enterPlacement`, `handle(.sidebarSlot(1))` (re-pick) → `.enterPlacement(type: 0)` (type from slot 1).
- `handle(.mapTile(...))` without an active placement → `.none`.
- `handle(.outside)` at any state → `.none`.

## 8. Manual verification (can't be automated)

Because the sidebar visuals live in SpriteKit + AppKit, the sandbox can't drive them. After this slice lands, run `swift run duneii` and verify:

1. **Boot**: launch to main menu; click "Start a new game"; scene loads scenario 1 (Atreides).
2. **Sidebar visible**: right-hand 128pt column shows a vertical stack of icons. For mission 1 (Atreides, campaign 0, only starting structures), expect at least three options: SLAB_1x1, WINDTRAP, and REFINERY (since the Atreides start with a WINDTRAP which unlocks REFINERY). If the starting conditions include an OUTPOST or LIGHT_VEHICLE, additional rows appear.
3. **Select → placement mode**: click the WINDTRAP slot. The slot's outline changes (indicator of selection).
4. **Commit**: click an empty tile near the player's base. A new windtrap-outlined rectangle appears at that tile. The HUD counter "structures N" increments.
5. **Sidebar refresh**: after commit, the sidebar re-populates. If REFINERY wasn't previously available, it now appears.
6. **Fallback**: click an empty part of the scene (not sidebar, not after selection) — scene routes back to main menu (preserves pre-slice behaviour).

Anything that fails in this checklist is a slice-3 regression that tests can't catch.

## 9. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/StructureInfo.swift` — `buildableTypes(from:)` helper.
- `Code/Core/Sources/DuneIIRendering/Scene/BuildPanelController.swift` — new file.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — sidebar rendering + click routing.
- `Code/Core/Tests/DuneIICoreTests/BuildPanelTests.swift` — both pure suites live here even though the controller is in the Rendering module (the test target already depends on both).
