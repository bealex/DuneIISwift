# Build panel tightening — cancel, queue-swap, rally tile (slice 5c)

Status: Drafted 2026-04-21 (P5 slice 5c — closing 5b's UX gaps).

Slice 5b landed the factory loop end-to-end but left three small UX gaps:

1. **No cancel** — clicking a BUSY yard did nothing. Mis-queued a SIEGE_TANK on your sole HV factory? Wait 96 ticks.
2. **No queue-swap on READY** — READY slot click on a *different* type was a no-op; slice 4d-ui specifically deferred this to avoid scope creep.
3. **Units overlap the factory visually on spawn** — new units spawn at the factory anchor tile.

Slice 5c closes all three. Each change is small and well-scoped; bundling them into one commit keeps the diff manageable since they all touch the controller + `Simulation.Structures`.

References:

- `src/structure.c:Structure_CancelBuild` — cancel path (we port the state reset; credit refund is deferred with economy).
- OpenDUNE's rally-point / factory-exit logic is spread across the factory window code + `Unit_Create`'s initial tile choice. We pick a simpler heuristic (see §4).

## 1. `Simulation.Structures.cancelConstruction`

```swift
@discardableResult
public static func cancelConstruction(
    yardIndex: Int,
    pool: inout StructurePool
) -> Bool
```

Resets a BUSY or READY yard to IDLE — clears `objectType`, `countDown`, and flips `state = IDLE`. Returns `true` on success. On IDLE / out-of-range / freed slots returns `false` with no pool mutation.

Unlike OpenDUNE's `Structure_CancelBuild` we:

- Accept any of BUSY / READY (OpenDUNE allows both via `linkedID == 0xFF` check; equivalent in our simpler model since we don't pre-allocate the produced object).
- Skip the credit refund. Credit state is deferred with the HUD / economy slice; plumbing a `House` credits field here would drag in half a subsystem.

## 2. `BuildPanelController` state transitions

Three new rules inside `handle(click:)`:

- `BUSY + sidebarSlot matching queuedType` → `.cancelConstruction(type:)` (new action).
- `BUSY + sidebarSlot on different type` → `.none` (unchanged; can't swap during BUSY).
- `READY + sidebarSlot on different type` → `.enqueue(type:)` (swap — replaces the ready-to-place object with a fresh build).

New `Action` case:

```swift
case cancelConstruction(type: UInt8)
```

The scene responds by calling `Simulation.Structures.cancelConstruction` and refreshing the sidebar.

## 3. Scene plumbing

`ScenarioScene.mouseDown` switch grows a `.cancelConstruction` arm:

```swift
case .cancelConstruction(let type):
    cancelConstructionOnYard(type: type)  // new helper
```

`cancelConstructionOnYard(type:)`: looks up the selected yard, calls `Structures.cancelConstruction`, refreshes the sidebar, logs the outcome.

## 4. `Simulation.Structures.factorySpawnTile(yardType:anchorX:anchorY:)`

```swift
public static func factorySpawnTile(
    yardType: UInt8, anchorX: Int, anchorY: Int
) -> (x: Int, y: Int)
```

Returns the tile where a unit should appear when a factory completes production. Heuristic:

- Look up the factory's footprint dimensions (`StructureInfo.layout.dimensions`).
- Exit tile = `(anchorX, anchorY + height)` — just south of the footprint's south-west corner.
- If that's out of bounds (`y >= 64`), fall back to `(anchorX, anchorY)` — the anchor, overlapping the building.

This is a deliberate approximation of OpenDUNE's richer rally-point logic. It's good enough for mission-play: every factory on mission 1 has at least one rock tile south of it, so units spawn cleanly. Corner-of-map factories will visually overlap; slice 5d can add collision-aware exit picking + a click-to-rally interaction.

`completeConstruction` in `Structures.swift` now routes through `factorySpawnTile` instead of hard-coding the anchor.

## 5. What slice 5c does NOT cover

- **Credit refund on cancel** — `Structure_CancelBuild` refunds `(buildTime - countDown/256) × buildCredits / buildTime`; deferred until `House` credits land.
- **Rally-point click** — OpenDUNE lets the player right-click a map tile while a factory is selected to set a rally point. Deferred.
- **Collision-aware exit picking** — if south-of-factory is occupied by another structure/unit, we still spawn there (and overlap). Deferred.
- **Auto-build-next-item** — cancel doesn't chain to the next queued buildable, because we don't queue more than one item at a time yet.

## 6. Testing

Extend `FactoryBuildableTests` + `BuildPanelTests`:

### `cancelConstruction`

- On BUSY yard → `true`, state → IDLE, objectType → 0xFFFF, countDown → 0.
- On READY yard → `true`, same reset.
- On IDLE yard → `false`, no mutation.
- Out-of-range / unallocated → `false`.

### `factorySpawnTile`

- BARRACKS (2x2) at (5, 5) → (5, 7).
- HEAVY_VEHICLE (3x2) at (10, 10) → (10, 12).
- HIGH_TECH (3x2) at (60, 62) — south tile y=64 out of bounds → (60, 62) anchor fallback.
- Invalid yard type → anchor fallback.

### `completeConstruction` uses `factorySpawnTile`

- BARRACKS at (5, 5) + READY SOLDIER → unit at (5, 7), not (5, 5).

### `BuildPanelController` new transitions

- BUSY + click on queuedType → `.cancelConstruction(type:)`.
- BUSY + click on different type → `.none` (unchanged).
- READY + click on different type → `.enqueue(type:)` (queue-swap).
- The old "READY + different type = no-op" test gets updated / replaced.

## 7. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `cancelConstruction` + `factorySpawnTile` + updated `completeConstruction`.
- `Code/Core/Sources/DuneIIRendering/Scene/BuildPanelController.swift` — new `.cancelConstruction` action + BUSY / READY swap transitions.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — handle `.cancelConstruction` + `cancelConstructionOnYard` helper.
- `Code/Core/Tests/DuneIICoreTests/FactoryBuildableTests.swift` — extended.
- `Code/Core/Tests/DuneIICoreTests/BuildPanelTests.swift` — extended.
