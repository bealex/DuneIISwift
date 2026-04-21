# Build panel — factory UI + yard switching (slice 5b)

Status: Drafted 2026-04-21 (P5 slice 5b — UI surface for slice 5a's factory buildable data).

Slice 5a added the data layer for factory unit production. Slice 5b surfaces it in the scene: clicking a player-owned factory (or the CY) on the map switches `selectedYardIndex` to that slot; the sidebar dispatches to the right buildable query based on the yard's type; the controller enqueues either a structure (on a CY) or a unit (on a factory) — the construction state machine runs unchanged on top.

Unit spawn on completion, per-unit `buildTime`, and factory-appropriate sidebar icons are all explicitly deferred (see §6). This slice is the "you can click factories now" gate.

References:

- `src/structure.c:Structure_GetBuildable` — case already ported in slice 5a.
- OpenDUNE `GUI_Widget_SelectStructure` — the equivalent click handler. We don't port pixel-level semantics.

## 1. `Simulation.Structures.selectableYardAt`

Pure helper:

```swift
public static func selectableYardAt(
    tileX: Int, tileY: Int,
    pool: StructurePool,
    playerHouseID: UInt8
) -> Int?
```

Walks `pool.findArray`. For each used+allocated slot: if `slot.houseID == playerHouseID` AND `slot.type` is a selectable yard (`CYARD == 8` OR one of `{3, 4, 5, 7, 10}` — the 5 factories), and the slot's footprint covers `(tileX, tileY)`, returns the pool index. Returns `nil` otherwise.

STARPORT (11) is a "yard" but its buildable is deferred to a later slice — we exclude it from selectability in 5b so clicking a starport doesn't give an empty / confusing sidebar.

## 2. `startConstruction` now accepts factory yards

The existing `Simulation.Structures.startConstruction(yardIndex:objectType:pool:)` gates on `slot.type == 8` (CYARD). Slice 5b relaxes that to accept `{3, 4, 5, 7, 8, 10}`. `objectType` is still a UInt8: for CY it's a structure type (0..18); for factories it's a unit type (0..26). The yard doesn't care; callers know by context.

Countdown source: `StructureInfo.buildTime` (yard type) for now. **Known divergence from OpenDUNE**: OpenDUNE uses the *produced object's* `buildTime`, so a BARRACKS building an INFANTRY takes INFANTRY's 25 seconds, not BARRACKS's 72. Since our scheduler runs at the same cadence regardless, the player sees a progress bar that's close-but-not-exact. Slice 5b-build (next) adds `UnitInfo.buildTime` + dispatches the countdown source by yard kind.

## 3. Scene changes

**Yard-switch on map click** (`ScenarioScene.mouseDown`): before routing the click through the controller, check if the click is on a map tile (not sidebar) and hits a player-owned selectable yard via `selectableYardAt`. If so, and we're not currently in placement mode, update `buildController.selectedYardIndex`, refresh the sidebar, log the switch, and return. Otherwise fall through to the existing controller flow.

**Sidebar dispatch** (`ScenarioScene.refreshBuildSidebar`): branches by `yard.type`:

- CYARD: existing path. `buildableStructuresFromYard` → `buildableTypesByPriority`.
- One of the 5 factories: `buildableUnitsFromFactory` → `UnitInfo.buildableUnitTypes(from:)` (new helper that returns sorted ascending unit-type — OpenDUNE's factory window doesn't sort units by priority the way structures do).
- Anything else: empty list.

Scene tracks `currentYardKind: enum { structure, unit }` so `renderSidebar` knows which short-name / icon path to take.

**Unit icon rendering**: slice 5b uses the label-only sidebar row for units. Slice 5b-build adds the sprite atlas lookup (`UnitSpriteAtlas.resolveFrame(info: .init(orientation: 0))` → texture lookup via `houseID`). Structure rows keep the existing ICN-tile lookup.

**Short-name fallback**: extend `shortName(for:)` to a new `shortUnitName(for:)` for UNIT type IDs; scene chooses based on `currentYardKind`.

## 4. `UnitInfo.buildableUnitTypes(from:)` helper

New static method mirroring `StructureInfo.buildableTypes(from:)` for units. Ascending unit-type order. Bits 27..31 ignored.

## 5. Controller changes

None. `BuildPanelController.availableTypes: [UInt8]` is already polymorphic between structure and unit type IDs — the caller (scene) knows the interpretation. The `.enqueue(type:)` action fires regardless; scene's `enqueueConstruction(type:)` calls `Structures.startConstruction` which now handles both yard kinds.

The "BUSY yard progress bar" logic already keys on `queuedType` equality with each row's type, so it continues to work for factories too.

## 6. What slice 5b does NOT cover

- **Unit spawn on completion** — factories currently flip to READY but clicking placement does nothing (structures.create expects a structure type). Slice 5b-build routes the completion path to `Simulation.Units.create` (or equivalent) spawning a new unit at the factory's exit tile.
- **Unit-appropriate `buildTime`** — factories use `StructureInfo.buildTime` until slice 5b-build.
- **Unit sidebar icons** — label-only for slice 5b; slice 5b-build adds atlas lookup.
- **STARPORT** — clicking a starport doesn't select it; the starport buildable remains deferred.
- **Rally point** — OpenDUNE lets players set a post-spawn destination. Deferred indefinitely.

## 7. Testing

Extend `FactoryBuildableTests` + `StructureConstructionTests`:

- `selectableYardAt`: CY match, LV factory match, REFINERY doesn't match, enemy CY doesn't match, empty pool → nil, click outside any footprint → nil.
- `startConstruction` on LV factory with TRIKE (unit type 13): now returns true, flips BUSY.
- `startConstruction` on REFINERY with any type: still false (REFINERY not a factory).

No controller tests (no contract change).

## 8. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `selectableYardAt` + relaxed `startConstruction`.
- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift` — `buildableUnitTypes(from:)`.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — yard-switch handler + sidebar dispatch + unit short-name helper.
- `Code/Core/Tests/DuneIICoreTests/FactoryBuildableTests.swift` — `selectableYardAt` + factory startConstruction cases.
