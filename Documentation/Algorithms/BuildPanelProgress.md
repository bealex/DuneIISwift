# Build panel progress — UI surface for the construction state machine (slice 4d-ui)

Status: Drafted 2026-04-21 (P5 slice 4d-ui — user-visible half of the construction state machine).

Slice 4d-sim flips the yard BUSY and drains `countDown` each scheduler tick. Slice 4d-ui surfaces that state in the sidebar and in the click flow:

- Clicking a sidebar slot on an IDLE yard → `Simulation.Structures.startConstruction(...)`, yard goes BUSY.
- A BUSY yard shows a progress bar on the slot matching `yard.objectType`.
- A READY yard shows a distinct highlight on the same slot; only then does clicking the slot enter placement mode.
- Map-clicks during placement commit as before (slice 3 + 4a/b/c gates unchanged).
- Re-clicking during BUSY / clicking a different type during READY: no-op (slice 4d-ui deliberately avoids cancel + queue-swap — those are 4e territory).

## 1. `BuildPanelController` additions

```swift
public var yardState: Simulation.StructureState?   // nil = no yard selected
public var queuedType: UInt8?                      // what the yard is building
public var countDown: UInt16?                      // current ticks left
public var buildTime: UInt16?                      // original ticks (for % math)

public enum Action: Equatable, Sendable {
    case none
    case enqueue(type: UInt8)                      // NEW — startConstruction
    case enterPlacement(type: UInt8)               // unchanged
    case commitPlacement(type: UInt8, tileX: Int, tileY: Int)
}

public mutating func refreshYardState(
    _ state: Simulation.StructureState?,
    queuedType: UInt8?,
    countDown: UInt16?,
    buildTime: UInt16?
)
```

Updated `handle(click:)`:

```
sidebarSlot(i):
    type = availableTypes[i]
    match yardState:
        nil | idle | justBuilt | detect:
            placementType = nil; return .enqueue(type: type)
        busy:
            return .none  // wait for READY
        ready:
            if type == queuedType {
                placementType = type; return .enterPlacement(type: type)
            }
            return .none
mapTile(x, y):
    if placementType != nil → commit + clear placementType
    else → .none
outside: .none
```

Computed helper `progress: Double?` returns `(buildTime - countDown/256) / buildTime` when both are non-nil, else nil. Used by the sidebar to size the progress bar.

## 2. Scene wiring

Three changes to `ScenarioScene`:

- `refreshBuildSidebar()` reads the selected yard's `state` + `objectType` + `countDown` and passes them to `controller.refreshYardState(...)`. Also passes `buildTime` resolved from the type's `StructureInfo`.
- `mouseDown` handles the new `.enqueue(type:)` case: call `Simulation.Structures.startConstruction(yardIndex:objectType:pool:)`, log, refresh.
- `update(_:)` calls `refreshBuildSidebar()` after every tick (not every frame — 12 Hz) so progress animates smoothly.

Sidebar rendering (`renderSidebar`):

- For each slot, draw the base rect + icon + label (unchanged).
- If `controller.queuedType == type` and `yardState == .busy`: overlay a progress-bar fill (`SKShapeNode` inside the slot with width = `slotWidth * progress`). Yellow colour.
- If `controller.queuedType == type` and `yardState == .ready`: slot outline becomes green (distinct from selection yellow + idle grey).

## 3. What slice 4d-ui does NOT cover

- **Cancel** — re-clicking a BUSY slot doesn't cancel. `Structure_CancelBuild` + UI wiring is a later slice.
- **Queue-swap on READY** — clicking a different type while the yard is READY in OpenDUNE replaces the objectType. Slice 4d-ui treats it as a no-op.
- **Multiple yards** — the scene still auto-selects the first player CY. Yard switch via map-click is separate scope.
- **Starport / factory progress bars** — only CONSTRUCTION_YARD goes through this UI. Unit-production buildings need slice 5.
- **Audio cues ("Production complete")** — deferred.

## 4. Testing

Extend `BuildPanelTests`:

- IDLE yard + sidebar click → `.enqueue(type: X)`.
- BUSY yard + sidebar click → `.none`.
- READY yard + sidebar click on queuedType → `.enterPlacement(type: X)`.
- READY yard + sidebar click on different type → `.none`.
- Nil yardState + sidebar click → `.enqueue(type: X)` (degrade to "start" behaviour when the scene hasn't populated state yet).
- `refreshYardState` then subsequent clicks: flow evolves correctly.
- `progress` math: `buildTime=48, countDown=12288` → 0.0; `countDown=0` → 1.0; `countDown=6144` → 0.5.

Pure controller tests; no SpriteKit. SpriteKit sidebar rendering stays manual-verification (same as slice 3).

## 5. Cross-link

- `Code/Core/Sources/DuneIIRendering/Scene/BuildPanelController.swift` — new fields + updated state transitions.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — refresh + sidebar rendering + `.enqueue` action.
- `Code/Core/Tests/DuneIICoreTests/BuildPanelTests.swift` — extended state transition suite.
