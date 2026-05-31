# Build GUI — the factory window + structure placement

The player-facing build flow in `duneii`: pick a factory → see what it can build → start a build → watch progress → (construction yard only) place the finished structure. This is the GUI layer over the already-headless build economy (`Structure_BuildObject`, the `structureTickStructure` build/repair/upgrade tick, `Structure_Place`). It closes the "player factory-window GUI" seam that the Phase-3 build slice left open (see `Algorithms/StructureScript.md`, `CurrentState.md`).

## What the sim already does

- **`UnitCombat.structureBuildObject(slot:objectType:)`** (`structure.c:1442`) — start a factory building a concrete `objectType` (a `UnitType.rawValue` for unit factories; a `StructureType.rawValue` for the construction yard). Creates the product off-map (`.isNotOnMap`), links it (`linkedID`), sets `countDown = buildTime << 8`, flips the factory to `.busy`.
- **`structureTickStructure`** (`GameLoop_Structure`) — advances `countDown` each tick by the HP/AI-scaled `buildSpeed`, deducting credits; at 0 the factory goes `.ready` (and `.onHold` if the house runs out of money).
- **Unit factories auto-deploy.** When a unit factory is `.ready`, its `BUILD.EMC` script (`unloadLinkedUnit`/`findUnitByType`) walks the unit out to a free ring tile and resets the factory to `.idle`. So unit production needs **no** placement UI — start it and the unit appears.
- **The construction yard does not auto-deploy.** A finished structure waits in the factory (`.ready`, `linkedID` → off-map product) until the player places it.
- **`Structure_Place` / `Structure_IsValidBuildLocation`** (`structure.c:442`/`734`) — validate a footprint (in-bounds, on slab-or-penalty terrain, unoccupied) and stamp the structure onto the map.

## New seam pieces (this feature)

### Query — `Simulation.buildables(forStructure:)`
A read-only port of **`Structure_GetBuildable`** (`structure.c:1834`). Returns `[Buildable]` (`objectType`, `isStructure`, `cost`, `buildTime`) for the items a factory can currently produce, filtered by the house's `structuresBuilt`, the unit/structure `structuresRequired` + `availableHouse` + `availableCampaign`, the active `campaignID`, and the factory's `upgradeLevel` (Ordos trike→raider-trike and siege-tank upgrade quirks included). Unit factories list units; the construction yard lists structures (slabs/walls/turrets/silos included); the starport is a seam (returns empty). We do **not** mutate the global `g_table_*Info[].available` flag (a GUI side-effect in OpenDUNE); the buildable set is the return value. Upgrade-first (`available == -1`) items are omitted from the list for the first version.

### Query — `Simulation.buildState(structureSlot:)`
The factory's current build, or `nil` when idle: the `objectType`, `isStructure`, `progress` (`1 - countDown / (buildTime << 8)`, `0…1`), `isReady` (`state == .ready`), and `onHold`. Drives the progress bar + the "Place it"/cancel affordances.

### Query — `Simulation.placementValidity(type:tile:)`
Wraps the internal `structureIsValidBuildLocation` so the placement preview can colour valid/invalid (≥1 = ok, 0 = blocked, <0 = buildable-but-missing-slabs).

### Command seam (`DuneIIContracts/Command.swift`)
Three new cases, applied through `UnitOrders.apply` (which builds a `UnitCombat` from its injected primitives):
- **`.build(structure:objectType:)`** → `structureBuildObject`.
- **`.cancelBuild(structure:)`** → `GameState.structureCancelBuild` (frees the off-map product, refunds the unbuilt remainder).
- **`.placeStructure(structure:tile:)`** → `UnitCombat.structurePlaceReady` (below).

### `UnitCombat.structurePlaceReady(factory:position:)`
The construction-yard place flow, fusing the two GUI steps (`widget_click.c:101` STR_PLACE_IT release + `viewport.c:205` place): require the CY `.ready` with a linked product, `Structure_Place` the product at `position`, and on success reset the factory (`linkedID = 0xFF`, `objectType = 0xFFFF`, `countDown = 0`, `state = .idle`). A placed **refinery** gets the house's first harvester via the existing `houseEnsureHarvesterAvailable` (OpenDUNE spawns one per refinery via `Unit_CreateWrapper`; the per-refinery spawn is a minor seam — `EnsureHarvester` covers the common first-refinery case). Returns false (leaving the factory ready) if the location is invalid, so the UI can keep placement mode active for another click.

## App flow (`duneii`)

- **Selector + progress** live in the Selection inspector (`InspectorPanel`) when a **player-owned factory** is selected. The build list shows each buildable item's name + credit cost; a button starts it (disabled while already building, or greyed when `cost > credits`). While building, a labelled `ProgressView` shows `buildState.progress`, with **Cancel** and (when `isReady` on a construction yard) **Place it**.
- **Placement mode** (`GameModel.placement`): "Place it" reads the ready product's `StructureType` + footprint and arms placement. In `GameScene`, a footprint overlay follows the cursor (`mouseMoved`), tinted green/red by `placementValidity`; a left-click on a valid tile enqueues `.placeStructure` and exits; `Esc`/right-click cancels. Build/place/cancel are queued onto `GameModel`'s command queue and applied next `advance()` alongside the unit-order commands.

## Not modelled (seams, deferred)

Starport stock + frigate ordering; the `available == -1` "upgrade to unlock" listing; build/placement hint + voice text; AI auto-placement; the per-refinery (vs first-refinery) harvester spawn.
