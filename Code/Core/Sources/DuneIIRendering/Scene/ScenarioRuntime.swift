import Foundation
import DuneIICore
import Memoirs

/// Non-visual game runtime. Owns the full simulation state + the two
/// input state-machines (`BuildPanelController`, `UnitCommandController`)
/// that translate player intent into sim mutations. Exposes clean
/// `leftClick`/`rightClick`/`sidebarClick`/`tick` intent methods that
/// both `ScenarioScene` (SpriteKit renderer) and `duneii-headless`
/// (stdin REPL) drive.
///
/// Concurrency: `@MainActor` — the scheduler, host, and pools are all
/// main-actor-bound, matching the scene's isolation.
///
/// Design note: a previous iteration buried this logic inside
/// `ScenarioScene`, making it untestable without an `SKView` and
/// unreachable from a headless harness. This type is the non-visual
/// core; the scene is a thin renderer on top.
@MainActor
public final class ScenarioRuntime {

    public enum RuntimeError: Error, CustomStringConvertible {
        case scenarioNotFound(String)
        case notLoaded

        public var description: String {
            switch self {
            case .scenarioNotFound(let n): return "scenario \(n) not in install"
            case .notLoaded: return "no scenario loaded"
            }
        }
    }

    public enum YardKind: Sendable, Equatable { case structure, unit }

    /// Structured result of a click. The scene uses it to drive visual
    /// refresh; the harness prints it as JSON. Every non-`.none` value
    /// represents one sim-side change.
    public enum ClickOutcome: Equatable, Sendable {
        case none
        case unitSelected(Int)
        case unitDeselected
        case orderMove(unitIdx: Int, tileX: Int, tileY: Int, ok: Bool)
        case orderAttack(attacker: Int, target: Int, ok: Bool)
        case orderAttackStructure(attacker: Int, targetStructureIndex: Int, ok: Bool)
        case yardSelected(Int)
        /// A structure was selected via map click — any owner, any
        /// type. The info panel reads the pool slot directly.
        case structureSelected(Int)
        case placementStarted(type: UInt8)
        case placementCommitted(type: UInt8, slot: Int, tileX: Int, tileY: Int, degraded: Bool)
        case placementRejected(type: UInt8, tileX: Int, tileY: Int)
        case placementPoolFull(type: UInt8, tileX: Int, tileY: Int)
        case constructionEnqueued(yardIdx: Int, type: UInt8, ok: Bool)
        case constructionCancelled(yardIdx: Int, type: UInt8)
        case factorySpawned(yardIdx: Int, unitIdx: Int, type: UInt8)
        case factoryPoolFull(yardIdx: Int, type: UInt8)
        case rallySet(yardIdx: Int, tileX: Int, tileY: Int)
        case rallyCleared(yardIdx: Int)
        /// Keyboard-staged harvest order resolved on a map click.
        case orderHarvest(unitIdx: Int, tileX: Int, tileY: Int, ok: Bool)
        /// Keyboard-staged return order — runtime picked the nearest
        /// same-house refinery and issued a move + action=RETURN.
        case orderReturn(unitIdx: Int, refineryIdx: Int?, ok: Bool)
        /// Shortcut was primed (key pressed) or was rejected for the
        /// current selection.
        case actionStaged(UnitCommandController.StagedAction)
        case actionStageRejected
        /// STARPORT slice 5c-ui outcomes. The `Opened` case wires the
        /// scene's sidebar into cart-panel mode (by reading
        /// `runtime.starportController`); mutation cases are cheap
        /// redraws; `Committed` carries the count of successfully
        /// chained units (may be fewer than requested if the unit
        /// pool ran out) and drops the panel; `Cancelled` just drops
        /// the panel with no commit and no credit change (credits
        /// already auto-refunded because the controller's drain is
        /// purely virtual until Send).
        case starportOpened(structureIndex: Int)
        case starportCartUpdated
        case starportCommitted(chained: Int)
        case starportCancelled
    }

    public let assets: AssetLoader
    public let playerHouseID: UInt8
    public private(set) var scheduler: Simulation.Scheduler?
    public var buildController = BuildPanelController()
    public var commandController = UnitCommandController()
    /// Pool slot of the currently-inspected structure. Set on any
    /// left-click that lands on a structure footprint — regardless of
    /// owner — so the scene's info panel can render name / HP / state.
    /// Independent of `buildController.selectedYardIndex`, which drives
    /// the build sidebar for player-owned CYARD / factories only.
    /// `nil` when no structure is selected or the last-selected slot
    /// has been freed.
    public var selectedStructureIndex: Int?
    /// Live CHOAM cart panel (STARPORT slice 5c-ui). `nil` when no
    /// starport panel is open. Instantiated in `leftClick` when the
    /// player clicks a friendly STARPORT; mutated by the
    /// `starportIncrement` / `starportDecrement` entry points; cleared
    /// on `starportCommit` / `starportCancel`.
    public var starportController: StarportController?
    /// Live tile grid. Held in a class box so closures captured by the
    /// scheduler's `landscapeAt` + `tileEnterScore` see runtime
    /// mutations (placed slabs, new structures) without being rebuilt.
    private let tileGridRef = TileGridRef()
    public var tileGrid: [Simulation.WorldSnapshot.Tile] { tileGridRef.tiles }
    public private(set) var tickCounter: Int = 0
    public private(set) var currentYardKind: YardKind = .structure
    public private(set) var scenarioName: String?
    /// Playable tile rect for the loaded scenario — port of
    /// OpenDUNE's `g_mapInfos[mapScale]`. Defaults to the full grid
    /// before a scenario is loaded.
    public private(set) var playableRect: (originX: Int, originY: Int, width: Int, height: Int) = (0, 0, 64, 64)

    private final class TileGridRef: @unchecked Sendable {
        var tiles: [Simulation.WorldSnapshot.Tile] = []
    }

    public init(
        assets: AssetLoader,
        playerHouseID: UInt8 = Simulation.House.atreides
    ) {
        self.assets = assets
        self.playerHouseID = playerHouseID
    }

    public var host: Scripting.Host? { scheduler?.host }

    // MARK: Scenario load + tick

    public func load(scenarioName name: String) throws {
        guard let scenario = try assets.loadScenario(named: name) else {
            throw RuntimeError.scenarioNotFound(name)
        }
        let resolver = assets.tileResolver
        let snapshot = try Simulation.WorldSnapshot(scenario: scenario, resolver: resolver)
        tileGridRef.tiles = snapshot.tiles
        // Trim the rendered tile grid to the scenario's playable
        // rect — port of OpenDUNE's `g_mapInfos[mapScale]` bounding
        // box. Tiles outside the rect get the veiled (fog-of-war
        // offset 16) sprite so the scene, minimap, and screenshot
        // renderer all show a black border matching the in-game look.
        let rect = scenario.playableRect
        playableRect = rect
        let veiled = resolver.veiledTileID
        var trimmedCount = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let inside = x >= rect.originX && x < rect.originX + rect.width
                    && y >= rect.originY && y < rect.originY + rect.height
                if inside { continue }
                let cellIdx = y * 64 + x
                let old = tileGridRef.tiles[cellIdx]
                if old.groundTileID == veiled { continue }
                tileGridRef.tiles[cellIdx] = Simulation.WorldSnapshot.Tile(
                    groundTileID: veiled,
                    overlayTileID: old.overlayTileID,
                    houseID: 0,
                    isUnveiled: false,
                    hasUnit: old.hasUnit,
                    hasStructure: old.hasStructure,
                    hasAnimation: old.hasAnimation,
                    hasExplosion: old.hasExplosion,
                    objectRef: old.objectRef
                )
                trimmedCount &+= 1
            }
        }
        Log.info(
            "runtime playable rect=(\(rect.originX),\(rect.originY),\(rect.width),\(rect.height)) trimmed=\(trimmedCount) veiledTileID=\(veiled)",
            tracer: .label("runtime")
        )
        // Stamp every scenario-spawned structure's footprint with
        // `hasStructure = true` + the owner's houseID so the
        // pathfinder + passability gate see them as impassable. The
        // plain `Map.Generator` used by `WorldSnapshot.init(scenario:)`
        // doesn't apply structure placements (that's ScenarioWorld's
        // job, which we only use for rendering).
        let iconMap = assets.iconMap
        for idx in snapshot.structures.findArray {
            let s = snapshot.structures.slots[idx]
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            // Pre-compute the iconGroup tile IDs the same way
            // `stampPlacement` does for runtime-placed structures
            // (Structure_UpdateMap offset = 2 × layoutSize, take next
            // layoutSize). Without this, scenario-placed structures
            // only set `hasStructure` on the grid but leave the
            // ground tiles as sand/rock, invisible to any consumer
            // that reads from tileGrid (minimap, screenshot tests).
            var iconTiles: [UInt16]? = nil
            if let groupRaw = Simulation.StructureInfo.iconGroupRawValue(for: s.type),
               let group = Formats.IconMap.Group(rawValue: groupRaw),
               let info = Simulation.StructureInfo.lookup(s.type)
            {
                let all = iconMap.tileIds(in: group)
                let (w, h) = info.layout.dimensions
                let needed = w * h
                let start = 2 * needed
                if all.count >= start + needed {
                    iconTiles = Array(all[start..<(start + needed)])
                } else if all.count >= needed {
                    let tail = all.count - needed
                    iconTiles = Array(all[tail..<(tail + needed)])
                }
            }
            let dims = Simulation.StructureInfo.lookup(s.type)?.layout.dimensions ?? (1, 1)
            for (fx, fy) in footprint {
                guard (0..<64).contains(fx), (0..<64).contains(fy) else { continue }
                let cellIdx = fy * 64 + fx
                guard cellIdx < tileGridRef.tiles.count else { continue }
                let old = tileGridRef.tiles[cellIdx]
                var newGround = old.groundTileID
                if let iconTiles {
                    let dx = fx - ax
                    let dy = fy - ay
                    let idx2 = dy * dims.0 + dx
                    if idx2 >= 0, idx2 < iconTiles.count {
                        newGround = iconTiles[idx2]
                    }
                }
                tileGridRef.tiles[cellIdx] = Simulation.WorldSnapshot.Tile(
                    groundTileID: newGround,
                    overlayTileID: old.overlayTileID,
                    houseID: s.houseID,
                    isUnveiled: old.isUnveiled,
                    hasUnit: old.hasUnit,
                    hasStructure: true,
                    hasAnimation: old.hasAnimation,
                    hasExplosion: old.hasExplosion,
                    objectRef: old.objectRef
                )
            }
        }
        let scorer = Self.makeTileEnterScorer(ref: tileGridRef, resolver: resolver)
        let landscapeLookup = Self.makeLandscapeLookup(ref: tileGridRef, resolver: resolver)
        let spiceMap = Self.makeSpiceMap(snapshot: snapshot, resolver: resolver)
        let repaint = Self.makeSpiceRepaint(ref: tileGridRef, resolver: resolver)
        let override = Self.makeGroundTileOverride(ref: tileGridRef)
        Log.info(
            "runtime spicemap seeded thick=\(spiceMap.cells.filter { $0 == .thick }.count) thin=\(spiceMap.cells.filter { $0 == .thin }.count)",
            tracer: .label("runtime")
        )
        let host = Scripting.Host(
            units: snapshot.units,
            structures: snapshot.structures,
            explosions: Simulation.ExplosionPool(),
            teams: snapshot.teams,
            houses: snapshot.houses,
            currentObject: nil,
            texts: [],
            textLog: [],
            voiceLog: [],
            tileEnterScore: scorer,
            playerHouseID: playerHouseID,
            isValidPosition: nil,
            isPositionUnveiled: nil,
            landscapeAt: landscapeLookup,
            spiceMap: spiceMap,
            spiceLevelDidChange: repaint,
            groundTileOverride: override
        )
        let source = Scripting.RandomSource(
            lcgSeed: UInt16(truncatingIfNeeded: scenario.mapField.seed),
            toolsSeed: scenario.mapField.seed
        )
        let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
        let structureFunctions = Scripting.Functions.structureTable(host: host, source: source)
        let teamFunctions = Scripting.Functions.teamTable(host: host, source: source)
        let unitProgram = ((try? assets.loadEmc(named: "UNIT.EMC")) ?? nil) ?? Formats.Emc.Program.empty
        let structureProgram = ((try? assets.loadEmc(named: "BUILD.EMC")) ?? nil) ?? Formats.Emc.Program.empty
        let teamProgram = ((try? assets.loadEmc(named: "TEAM.EMC")) ?? nil) ?? Formats.Emc.Program.empty
        let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
        let structureVM = Scripting.VM(program: structureProgram, functions: structureFunctions)
        let teamVM = Scripting.VM(program: teamProgram, functions: teamFunctions)
        let harvestRNG: () -> UInt8 = { source.tools.next() }
        var s = Simulation.Scheduler(
            host: host,
            unitVM: unitVM,
            structureVM: structureVM,
            teamVM: teamVM,
            harvestRNG: harvestRNG
        )
        s.bloomSandTileID = resolver.landscapeTileID
        // Seed the live CHOAM stock from the scenario's [CHOAM]
        // section. Keeps the per-game stock vector in one place —
        // mutated thereafter by commitStarportOrder / tickStarport*
        // passes (STARPORT slice 5b).
        s.starportStock = scenario.choamInventory
        // Clamp auto-harvester spice-seek + future per-tick passes to
        // the scenario's playable rect (`g_mapInfos[mapScale]`). Prior
        // to this, `findNearestSpiceTile` scanned all 4096 cells and
        // happily returned tiles outside the playable border.
        s.playableRect = rect
        scheduler = s
        tickCounter = 0
        scenarioName = name
        autoSelectPlayerYard()
        refreshBuildState()
        Log.info(
            "runtime loaded scenario=\(name) units=\(snapshot.units.findArray.count) structures=\(snapshot.structures.findArray.count)",
            tracer: .label("runtime")
        )
    }

    public func tick(_ n: Int = 1) {
        guard scheduler != nil else { return }
        for _ in 0..<n {
            scheduler?.tick()
            tickCounter += 1
        }
        refreshBuildState()
        validateSelections()
    }

    /// Drops stale structure / unit selections when the underlying
    /// slot has been freed. Called every tick; cheap no-op when
    /// nothing's selected.
    public func validateSelections() {
        guard let host else { return }
        if let idx = selectedStructureIndex {
            if idx < 0 || idx >= host.structures.slots.count ||
               !host.structures.slots[idx].isUsed
            {
                Log.info(
                    "selection: stale structure=\(idx) cleared",
                    tracer: .label("selection")
                )
                selectedStructureIndex = nil
            }
        }
    }

    /// `true` when `(tileX, tileY)` is inside the scenario's playable
    /// rect (`g_mapInfos[mapScale]`). Used to reject move-style orders
    /// that would let a unit walk into the veiled border — in Dune 2
    /// the player can't click there because the UI hides the region;
    /// our scene renders the whole 64×64 grid so stray clicks land on
    /// veiled tiles and used to dispatch all the way through `orderMove`.
    public func isInPlayableRect(tileX: Int, tileY: Int) -> Bool {
        return tileX >= playableRect.originX
            && tileX < playableRect.originX + playableRect.width
            && tileY >= playableRect.originY
            && tileY < playableRect.originY + playableRect.height
    }

    // MARK: Click intent

    @discardableResult
    public func leftClick(tileX: Int, tileY: Int) -> ClickOutcome {
        guard let host else { return .none }

        // 1. Unit-command first (when not mid-placement).
        if buildController.placementType == nil {
            let action = commandController.handle(
                click: .leftMapTile(x: tileX, y: tileY),
                pool: host.units,
                playerHouseID: playerHouseID,
                structures: host.structures
            )
            switch action {
            case .selectUnit(let idx, let isFriendly):
                Log.info(
                    "unit-select \(idx) friendly=\(isFriendly)",
                    tracer: .label("unit-cmd")
                )
                // Unit and structure selections are mutually exclusive —
                // clicking a unit tile drops any structure selection.
                selectedStructureIndex = nil
                return .unitSelected(idx)
            case .deselect:
                Log.info("unit-deselect", tracer: .label("unit-cmd"))
                // Don't clear selectedStructureIndex here — a click on
                // empty that "deselects a unit" shouldn't unseat a
                // structure selection made on the same click path.
                return .unitDeselected
            case .orderMove(let idx, let tx, let ty):
                guard isInPlayableRect(tileX: tx, tileY: ty) else {
                    Log.info(
                        "unit-order-move unit=\(idx) tile=(\(tx),\(ty)) REJECTED out-of-playable",
                        tracer: .label("unit-cmd")
                    )
                    return .orderMove(unitIdx: idx, tileX: tx, tileY: ty, ok: false)
                }
                let ok = Simulation.Units.orderMove(
                    poolIndex: idx, tileX: tx, tileY: ty, units: &host.units
                )
                Log.info(
                    "unit-order-move unit=\(idx) tile=(\(tx),\(ty)) ok=\(ok)",
                    tracer: .label("unit-cmd")
                )
                return .orderMove(unitIdx: idx, tileX: tx, tileY: ty, ok: ok)
            case .orderAttack(let attacker, let target):
                let ok = Simulation.Units.orderAttack(
                    poolIndex: attacker, targetUnitIndex: target, units: &host.units
                )
                Log.info(
                    "unit-order-attack unit=\(attacker) target=\(target) ok=\(ok)",
                    tracer: .label("unit-cmd")
                )
                return .orderAttack(attacker: attacker, target: target, ok: ok)
            case .orderAttackStructure(let attacker, let structIdx):
                // Left-click can now produce this case via the `A`
                // keyboard shortcut — stagedAction=.attack + click on
                // an enemy structure.
                let ok = Simulation.Units.orderAttackStructure(
                    poolIndex: attacker,
                    targetStructureIndex: structIdx,
                    units: &host.units,
                    structures: host.structures
                )
                Log.info(
                    "unit-order-attack-structure unit=\(attacker) target=s\(structIdx) ok=\(ok) (via shortcut)",
                    tracer: .label("unit-cmd")
                )
                return .orderAttackStructure(
                    attacker: attacker, targetStructureIndex: structIdx, ok: ok
                )
            case .orderHarvest(let idx, let tx, let ty):
                // Harvester shortcut: move to target + pin action to
                // HARVEST so tickHarvesting's seek-spice / drain path
                // takes over on arrival.
                guard isInPlayableRect(tileX: tx, tileY: ty) else {
                    Log.info(
                        "unit-order-harvest unit=\(idx) tile=(\(tx),\(ty)) REJECTED out-of-playable",
                        tracer: .label("unit-cmd")
                    )
                    return .orderHarvest(unitIdx: idx, tileX: tx, tileY: ty, ok: false)
                }
                let ok = Simulation.Units.orderMove(
                    poolIndex: idx, tileX: tx, tileY: ty, units: &host.units
                )
                var u = host.units[idx]
                u.actionID = Simulation.ActionID.harvest
                host.units[idx] = u
                Log.info(
                    "unit-order-harvest unit=\(idx) tile=(\(tx),\(ty)) ok=\(ok)",
                    tracer: .label("unit-cmd")
                )
                return .orderHarvest(unitIdx: idx, tileX: tx, tileY: ty, ok: ok)
            case .orderReturn(let idx):
                // Harvester shortcut: find nearest same-house refinery
                // (prefers unoccupied via 8a's findFreeRefinery) and
                // route there in RETURN action.
                let harvester = host.units.slots[idx]
                let freeIdx = Simulation.Scheduler.findFreeRefinery(
                    forHarvester: harvester, structures: host.structures
                )
                let refIdx = freeIdx ?? Simulation.Scheduler.findNearestRefinery(
                    forHarvester: harvester, structures: host.structures
                )
                var ok = false
                if let refIdx {
                    let r = host.structures.slots[refIdx]
                    let rx = Int(r.positionX) / 256
                    let ry = Int(r.positionY) / 256
                    ok = Simulation.Units.orderMove(
                        poolIndex: idx, tileX: rx, tileY: ry, units: &host.units
                    )
                    var u = host.units[idx]
                    u.actionID = Simulation.ActionID.returnAction
                    host.units[idx] = u
                }
                Log.info(
                    "unit-order-return unit=\(idx) refinery=\(refIdx.map(String.init) ?? "nil") ok=\(ok)",
                    tracer: .label("unit-cmd")
                )
                return .orderReturn(unitIdx: idx, refineryIdx: refIdx, ok: ok)
            case .none:
                break
            }
        }

        // 2. Generic structure selection — any owner, any type. Sets
        //    `selectedStructureIndex` so the info panel can render
        //    name / HP / state. Runs before the yard-select step so
        //    non-yard buildings and enemy structures get highlighted
        //    too (enemy → info-only, player non-yard → info + status).
        if buildController.placementType == nil,
           let structIdx = Self.structureAtTile(
               tileX: tileX, tileY: tileY, pool: host.structures
           ),
           structIdx != selectedStructureIndex
        {
            selectedStructureIndex = structIdx
            let s = host.structures.slots[structIdx]
            Log.info(
                "structure-select \(structIdx) type=\(s.type) house=\(s.houseID) friendly=\(s.houseID == playerHouseID)",
                tracer: .label("selection")
            )
            // STARPORT slice 5c-ui: friendly STARPORT click opens the
            // CHOAM cart panel. Only one panel at a time — clicking a
            // different STARPORT replaces the controller. Left-click
            // on the same structure is handled by the `!= selected`
            // guard above; left-click elsewhere while a panel is open
            // drops it via `starportController = nil` in the fall-
            // through below.
            if s.type == 11 /* STARPORT */, s.houseID == playerHouseID {
                let stock = scheduler?.starportStock ?? [Int16](repeating: 0, count: 27)
                let credits = host.houses.slots[Int(playerHouseID)].credits
                // Deterministic per-panel price seed. Ports the
                // `(scenarioID + playerHouseID + secondsElapsed/3600)`
                // spirit of OpenDUNE's `GUI_FactoryWindow_InitItems`
                // (`src/gui/gui.c:2749..2754`) without needing the
                // 60-second wall-clock — tickCounter is our proxy and
                // the seed just needs to be deterministic within a
                // session.
                let seed = UInt16(truncatingIfNeeded: tickCounter)
                    &+ UInt16(playerHouseID)
                    &+ UInt16(truncatingIfNeeded: scenarioName?.hashValue ?? 0)
                starportController = StarportController.open(
                    houseID: playerHouseID,
                    starportIndex: structIdx,
                    houseCredits: credits,
                    stock: stock,
                    priceSeed: seed
                )
                // Drop any build-panel yard selection so the sidebar
                // flips from "BUILD" mode to "CHOAM" mode cleanly.
                buildController.selectedYardIndex = nil
                refreshBuildState()
                Log.info(
                    "starport-open struct=\(structIdx) rows=\(starportController?.rows.count ?? 0) credits=\(credits)",
                    tracer: .label("starport")
                )
                return .starportOpened(structureIndex: structIdx)
            }
            // Any non-starport click drops a live panel (clicking
            // away cancels the cart).
            if starportController != nil {
                starportController = nil
                Log.info("starport-close (clicked away)", tracer: .label("starport"))
            }
            // Fall through so the yard-select step below still gets a
            // chance to wire the build sidebar for player-owned
            // CYARD / factories.
        }

        // 3. Yard select (when not mid-placement).
        if buildController.placementType == nil,
           let newYardIdx = Simulation.Structures.selectableYardAt(
               tileX: tileX, tileY: tileY, pool: host.structures, playerHouseID: playerHouseID
           ),
           newYardIdx != buildController.selectedYardIndex
        {
            buildController.selectedYardIndex = newYardIdx
            Log.info(
                "build-panel selected yard=\(newYardIdx) type=\(host.structures.slots[newYardIdx].type)",
                tracer: .label("build-panel")
            )
            refreshBuildState()
            return .yardSelected(newYardIdx)
        }

        // If we selected a non-yard structure (or the same yard as
        // before) return structureSelected rather than falling through
        // to the build-panel placeholder branch. BUT skip this short
        // circuit when the player is mid-placement — the click on the
        // map is meant to commit, not to re-announce the (stale)
        // structure selection that persists from autoSelectPlayerYard.
        if buildController.placementType == nil,
           let selIdx = selectedStructureIndex
        {
            return .structureSelected(selIdx)
        }

        // 4. Build-panel click-through (placement commits).
        let action = buildController.handle(click: .mapTile(x: tileX, y: tileY))
        return applyBuildAction(action)
    }

    /// Returns the pool index of a structure whose footprint covers
    /// `(tileX, tileY)`, or `nil`. Walks `findArray` — reserved
    /// aggregate slots (slabs, walls) aren't selectable.
    private static func structureAtTile(
        tileX: Int, tileY: Int, pool: Simulation.StructurePool
    ) -> Int? {
        for idx in pool.findArray {
            let s = pool.slots[idx]
            guard s.isUsed, s.isAllocated else { continue }
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            if footprint.contains(where: { $0.0 == tileX && $0.1 == tileY }) {
                return idx
            }
        }
        return nil
    }

    @discardableResult
    public func rightClick(tileX: Int, tileY: Int) -> ClickOutcome {
        guard let host else { return .none }

        // Unit command takes priority when a unit is selected.
        if commandController.selectedUnitIndex != nil {
            let action = commandController.handle(
                click: .rightMapTile(x: tileX, y: tileY),
                pool: host.units,
                playerHouseID: playerHouseID,
                structures: host.structures
            )
            switch action {
            case .orderMove(let idx, let tx, let ty):
                guard isInPlayableRect(tileX: tx, tileY: ty) else {
                    Log.info(
                        "unit-order-move unit=\(idx) tile=(\(tx),\(ty)) REJECTED out-of-playable",
                        tracer: .label("unit-cmd")
                    )
                    return .orderMove(unitIdx: idx, tileX: tx, tileY: ty, ok: false)
                }
                let ok = Simulation.Units.orderMove(
                    poolIndex: idx, tileX: tx, tileY: ty, units: &host.units
                )
                Log.info(
                    "unit-order-move unit=\(idx) tile=(\(tx),\(ty)) ok=\(ok)",
                    tracer: .label("unit-cmd")
                )
                return .orderMove(unitIdx: idx, tileX: tx, tileY: ty, ok: ok)
            case .orderAttack(let attacker, let target):
                let ok = Simulation.Units.orderAttack(
                    poolIndex: attacker, targetUnitIndex: target, units: &host.units
                )
                return .orderAttack(attacker: attacker, target: target, ok: ok)
            case .orderAttackStructure(let attacker, let structIdx):
                let ok = Simulation.Units.orderAttackStructure(
                    poolIndex: attacker,
                    targetStructureIndex: structIdx,
                    units: &host.units,
                    structures: host.structures
                )
                Log.info(
                    "unit-order-attack-structure unit=\(attacker) target=s\(structIdx) ok=\(ok)",
                    tracer: .label("unit-cmd")
                )
                return .orderAttackStructure(
                    attacker: attacker, targetStructureIndex: structIdx, ok: ok
                )
            default:
                return .none
            }
        }

        // Rally-point when a factory is selected and no unit.
        if let yardIdx = buildController.selectedYardIndex,
           yardIdx < host.structures.slots.count,
           Self.isFactory(type: host.structures.slots[yardIdx].type)
        {
            _ = Simulation.Structures.setRallyPoint(
                yardIndex: yardIdx, tile: (tileX, tileY), pool: &host.structures
            )
            return .rallySet(yardIdx: yardIdx, tileX: tileX, tileY: tileY)
        }

        return .none
    }

    @discardableResult
    public func sidebarClick(row: Int) -> ClickOutcome {
        let action = buildController.handle(click: .sidebarSlot(index: row))
        return applyBuildAction(action)
    }

    // MARK: - STARPORT slice 5c-ui

    /// Add one unit of `typeID` to the cart. Fails silently when no
    /// panel is open, the row doesn't exist, stock is exhausted, or
    /// the house can't afford the unit. Returns `.starportCartUpdated`
    /// on success for the scene to redraw; `.none` otherwise.
    @discardableResult
    public func starportIncrement(typeID: UInt8) -> ClickOutcome {
        guard var controller = starportController else { return .none }
        let ok = controller.increment(typeID: typeID)
        starportController = controller
        Log.debug(
            "starport-inc type=\(typeID) ok=\(ok) cartTotal=\(controller.cartTotal) credits=\(controller.availableCredits)",
            tracer: .label("starport")
        )
        return ok ? .starportCartUpdated : .none
    }

    /// Remove one unit of `typeID` from the cart. Fails silently when
    /// the panel isn't open, the row doesn't exist, or the cart has 0
    /// of that type.
    @discardableResult
    public func starportDecrement(typeID: UInt8) -> ClickOutcome {
        guard var controller = starportController else { return .none }
        let ok = controller.decrement(typeID: typeID)
        starportController = controller
        Log.debug(
            "starport-dec type=\(typeID) ok=\(ok) cartTotal=\(controller.cartTotal) credits=\(controller.availableCredits)",
            tracer: .label("starport")
        )
        return ok ? .starportCartUpdated : .none
    }

    /// Commit the cart. Port of the Send-button handler from the
    /// OpenDUNE factory-window commit loop: for every pending row,
    /// call `Simulation.Structures.commitStarportOrder(...)` which
    /// chains off-map units onto the house's `starportLinkedID` and
    /// decrements the live `Scheduler.starportStock`. Applies the
    /// virtual credit drain by writing `controller.availableCredits`
    /// back to the house. Clears the panel on success.
    @discardableResult
    public func starportCommit() -> ClickOutcome {
        guard let controller = starportController else { return .none }
        guard var scheduler else { return .none }
        guard let host else { return .none }
        let orders = controller.pendingOrders()
        if orders.isEmpty {
            Log.info("starport-commit empty cart — dropping panel", tracer: .label("starport"))
            starportController = nil
            return .starportCancelled
        }
        let deliveryTime = Simulation.Scheduler.starportDeliveryTimeByHouse[Int(playerHouseID)]
        var houses = host.houses
        var units = host.units
        var stock = scheduler.starportStock
        let chained = Simulation.Structures.commitStarportOrder(
            houseID: playerHouseID,
            orders: orders.map { ($0.typeID, $0.count) },
            houses: &houses,
            units: &units,
            stock: &stock,
            deliveryTime: deliveryTime
        )
        // Apply the cart's virtual credit drain. Controller tracks
        // `availableCredits` as the house's credits minus the cart
        // total, so writing that value back is a faithful "credits
        // spent" commit.
        var h = houses[Int(playerHouseID)]
        h.credits = controller.availableCredits
        houses[Int(playerHouseID)] = h
        host.houses = houses
        host.units = units
        scheduler.starportStock = stock
        self.scheduler = scheduler
        Log.info(
            "starport-commit requested=\(orders.reduce(0) { $0 + $1.count }) chained=\(chained) credits→\(h.credits)",
            tracer: .label("starport")
        )
        starportController = nil
        return .starportCommitted(chained: chained)
    }

    /// Discard the cart. Credits auto-refund because the controller's
    /// drain was virtual — we simply drop it without writing anything
    /// back to the house.
    @discardableResult
    public func starportCancel() -> ClickOutcome {
        guard starportController != nil else { return .none }
        starportController = nil
        Log.info("starport-cancel", tracer: .label("starport"))
        return .starportCancelled
    }

    /// Test-shaped setter for the live CHOAM stock. Scenarios pre-seed
    /// via `choamInventory` on load; mid-session mutation happens
    /// through `commitStarportOrder` + `tickStarportAvailability`.
    /// Tests that want a specific stock shape without re-loading can
    /// call this directly. No-ops when no scheduler has been loaded.
    public func setStarportStock(typeID: UInt8, count: Int16) {
        guard var scheduler else { return }
        let idx = Int(typeID)
        guard idx >= 0, idx < scheduler.starportStock.count else { return }
        scheduler.starportStock[idx] = count
        self.scheduler = scheduler
    }

    /// Keyboard shortcut — primes the next left-click to resolve as
    /// the given order instead of triggering selection. Harvest /
    /// Return require a harvester. Returns `.actionStaged` on
    /// success; `.actionStageRejected` when no friendly unit is
    /// selected or the action doesn't fit the selection.
    @discardableResult
    public func stageAction(_ action: UnitCommandController.StagedAction) -> ClickOutcome {
        guard let host else { return .actionStageRejected }
        let ok = commandController.stage(action: action, pool: host.units)
        if ok {
            Log.info("unit-stage action=\(action)", tracer: .label("unit-cmd"))
            return .actionStaged(action)
        }
        Log.info("unit-stage rejected action=\(action)", tracer: .label("unit-cmd"))
        return .actionStageRejected
    }

    /// Drops all current selections (unit + structure + yard
    /// placement). Called from the Escape-key shortcut and tests.
    public func deselect() {
        let hadUnit = commandController.selectedUnitIndex != nil
        let hadStructure = selectedStructureIndex != nil
        let hadPlacement = buildController.placementType != nil
        commandController.selectedUnitIndex = nil
        commandController.isFriendlySelection = false
        commandController.stagedAction = nil
        selectedStructureIndex = nil
        buildController.placementType = nil
        if hadUnit || hadStructure || hadPlacement {
            Log.info(
                "deselect all unit=\(hadUnit) structure=\(hadStructure) placement=\(hadPlacement)",
                tracer: .label("selection")
            )
        }
    }

    /// Selects the next friendly unit after the currently-selected
    /// one, wrapping around `findArray`. Skips bullets / projectiles
    /// and non-player units. Used by the Tab keyboard shortcut.
    /// Returns the newly-selected unit's pool index, or nil when the
    /// player owns no units.
    @discardableResult
    public func cycleToNextPlayerUnit() -> Int? {
        guard let host else { return nil }
        // Build an ordered list of player-owned, non-projectile units.
        let owned = host.units.findArray.filter { idx in
            let u = host.units.slots[idx]
            guard u.isUsed else { return false }
            guard u.houseID == playerHouseID else { return false }
            guard !Simulation.Scheduler.isProjectileType(u.type) else { return false }
            return true
        }
        guard !owned.isEmpty else {
            Log.debug("cycle-select: no player units", tracer: .label("selection"))
            return nil
        }
        let next: Int
        if let current = commandController.selectedUnitIndex,
           let currentPos = owned.firstIndex(of: current)
        {
            next = owned[(currentPos + 1) % owned.count]
        } else {
            next = owned[0]
        }
        commandController.selectedUnitIndex = next
        commandController.isFriendlySelection = true
        selectedStructureIndex = nil
        Log.info(
            "cycle-select next=\(next) (of \(owned.count) player units)",
            tracer: .label("selection")
        )
        return next
    }

    /// Direct yard selection (bypasses click routing). Useful for tests
    /// + harness.
    public func selectYard(index: Int) {
        guard let host else { return }
        guard index >= 0, index < host.structures.slots.count,
              host.structures.slots[index].isUsed else { return }
        buildController.selectedYardIndex = index
        refreshBuildState()
    }

    // MARK: Build-panel state refresh

    /// Recomputes available types + yard state for the selected yard.
    /// Pure state-machine update — no visual side effects. Called from
    /// scene on every tick so the progress bar animates; harness calls
    /// it after clicks that change yard state.
    public func refreshBuildState() {
        guard let host,
              let yardIdx = buildController.selectedYardIndex,
              yardIdx < host.structures.slots.count,
              host.structures.slots[yardIdx].isUsed
        else {
            buildController.refreshAvailableTypes([])
            buildController.refreshYardState(nil, queuedType: nil, countDown: nil, buildTime: nil)
            return
        }
        let yard = host.structures.slots[yardIdx]
        let built = Simulation.Structures.structuresBuilt(
            houseID: yard.houseID, pool: host.structures
        )
        let campaignID: UInt16 = 0

        let types: [UInt8]
        if yard.type == 8 /* CYARD */ {
            currentYardKind = .structure
            let mask = Simulation.Structures.buildableStructuresFromYard(
                yardHouseID: yard.houseID,
                yardUpgradeLevel: yard.upgradeLevel,
                structuresBuilt: built,
                campaignID: campaignID,
                playerHouseID: playerHouseID
            )
            types = Simulation.StructureInfo.buildableTypesByPriority(from: mask)
        } else {
            currentYardKind = .unit
            let mask = Simulation.Structures.buildableUnitsFromFactory(
                factoryType: yard.type,
                factoryHouseID: yard.houseID,
                factoryUpgradeLevel: yard.upgradeLevel,
                structuresBuilt: built
            )
            types = Simulation.UnitInfo.buildableUnitTypes(from: mask)
        }
        buildController.refreshAvailableTypes(types)

        let state = Simulation.StructureState(rawValue: yard.state)
        let queued: UInt8?
        let buildTime: UInt16?
        if yard.objectType == 0xFFFF {
            queued = nil
            buildTime = nil
        } else {
            queued = UInt8(truncatingIfNeeded: yard.objectType)
            if currentYardKind == .structure,
               let info = Simulation.StructureInfo.lookup(queued!)
            {
                buildTime = info.buildTime
            } else if let yardInfo = Simulation.StructureInfo.lookup(yard.type) {
                buildTime = yardInfo.buildTime
            } else {
                buildTime = nil
            }
        }
        buildController.refreshYardState(
            state,
            queuedType: queued,
            countDown: yard.countDown,
            buildTime: buildTime
        )
    }

    /// Validity for a potential placement. Returns `nil` when no host
    /// loaded; otherwise mirrors `isValidBuildLocation`: `0` invalid,
    /// `>0` valid, `<0` valid-but-degraded (slab deficit = -value).
    public func placementValidity(type: UInt8, tileX: Int, tileY: Int) -> Int? {
        guard let host else { return nil }
        let resolver = assets.tileResolver
        let tiles = tileGrid
        let landscapeAt: (Int, Int) -> LandscapeType = { x, y in
            guard x >= 0, x < 64, y >= 0, y < 64 else { return .entirelyMountain }
            let idx = y * 64 + x
            guard idx < tiles.count else { return .entirelyMountain }
            let cell = tiles[idx]
            return resolver.landscapeType(
                groundTileID: cell.groundTileID,
                overlayTileID: cell.overlayTileID,
                hasStructure: cell.hasStructure
            )
        }
        let tileHouseIDAt: (Int, Int) -> UInt8 = { x, y in
            guard x >= 0, x < 64, y >= 0, y < 64 else { return 0 }
            let idx = y * 64 + x
            guard idx < tiles.count else { return 0 }
            return tiles[idx].houseID
        }
        return Int(Simulation.Structures.isValidBuildLocation(
            tileX: tileX, tileY: tileY, type: type,
            structures: host.structures, units: host.units,
            landscapeAt: landscapeAt,
            playerHouseID: playerHouseID,
            tileHouseIDAt: tileHouseIDAt
        ))
    }

    // MARK: Internal — build-panel action dispatch

    private func applyBuildAction(_ action: BuildPanelController.Action) -> ClickOutcome {
        switch action {
        case .enqueue(let type):
            let ok = enqueueConstruction(type: type)
            let idx = buildController.selectedYardIndex ?? -1
            return .constructionEnqueued(yardIdx: idx, type: type, ok: ok)
        case .enterPlacement(let type):
            if currentYardKind == .unit {
                return completeFactoryProduction(type: type)
            }
            Log.info("build-panel enter placement type=\(type)", tracer: .label("build-panel"))
            refreshBuildState()
            return .placementStarted(type: type)
        case .commitPlacement(let type, let tileX, let tileY):
            return commitPlacement(type: type, tileX: tileX, tileY: tileY)
        case .cancelConstruction(let type):
            let idx = buildController.selectedYardIndex ?? -1
            cancelConstructionOnYard(type: type)
            return .constructionCancelled(yardIdx: idx, type: type)
        case .none:
            return .none
        }
    }

    @discardableResult
    private func enqueueConstruction(type: UInt8) -> Bool {
        guard let host, let yardIdx = buildController.selectedYardIndex else { return false }
        var pool = host.structures
        let ok = Simulation.Structures.startConstruction(
            yardIndex: yardIdx, objectType: type, pool: &pool
        )
        host.structures = pool
        Log.info(
            "build-panel enqueue type=\(type) yard=\(yardIdx) ok=\(ok)",
            tracer: .label("build-panel")
        )
        refreshBuildState()
        return ok
    }

    private func cancelConstructionOnYard(type: UInt8) {
        guard let host, let yardIdx = buildController.selectedYardIndex else { return }
        var pool = host.structures
        var houses = host.houses
        let ok = Simulation.Structures.cancelConstruction(
            yardIndex: yardIdx, pool: &pool, houses: &houses
        )
        host.structures = pool
        host.houses = houses
        Log.info(
            "build-panel cancel yard=\(yardIdx) type=\(type) ok=\(ok)",
            tracer: .label("build-panel")
        )
        refreshBuildState()
    }

    private func completeFactoryProduction(type: UInt8) -> ClickOutcome {
        guard let host, let yardIdx = buildController.selectedYardIndex else {
            return .none
        }
        var structures = host.structures
        var units = host.units
        let unitIdx = Simulation.Structures.completeConstruction(
            yardIndex: yardIdx, pool: &structures, unitPool: &units
        )
        host.structures = structures
        host.units = units
        buildController.placementType = nil
        refreshBuildState()
        if let unitIdx {
            Log.info(
                "build-panel factory yard=\(yardIdx) spawned unit=\(unitIdx) type=\(type)",
                tracer: .label("build-panel")
            )
            return .factorySpawned(yardIdx: yardIdx, unitIdx: unitIdx, type: type)
        } else {
            Log.info(
                "build-panel factory yard=\(yardIdx) FAILED (pool full) type=\(type)",
                tracer: .label("build-panel")
            )
            return .factoryPoolFull(yardIdx: yardIdx, type: type)
        }
    }

    private func commitPlacement(type: UInt8, tileX: Int, tileY: Int) -> ClickOutcome {
        guard let host else { return .none }
        let validityOpt = placementValidity(type: type, tileX: tileX, tileY: tileY)
        guard let validity = validityOpt, validity != 0 else {
            Log.info(
                "build-panel commit rejected — invalid tile=(\(tileX),\(tileY)) type=\(type) validity=\(validityOpt ?? 0)",
                tracer: .label("build-panel")
            )
            // Keep placement mode active so the caller can try again.
            return .placementRejected(type: type, tileX: tileX, tileY: tileY)
        }
        let tilesWithoutSlab = validity < 0 ? Int(-validity) : 0
        if validity < 0 {
            Log.info(
                "build-panel commit degraded tile=(\(tileX),\(tileY)) type=\(type) slabs_needed=\(tilesWithoutSlab)",
                tracer: .label("build-panel")
            )
        }
        let px = UInt16(clamping: tileX * 256)
        let py = UInt16(clamping: tileY * 256)
        var pool = host.structures
        let idx = Simulation.Structures.create(
            type: type,
            houseID: playerHouseID,
            position: Pos32(x: px, y: py),
            pool: &pool,
            tilesWithoutSlab: tilesWithoutSlab
        )
        host.structures = pool
        if let idx {
            // Stamp the tileGrid so subsequent landscape reads (placement
            // validity, pathfinder, passability gate) see the freshly
            // placed slab/structure.
            stampPlacement(type: type, tileX: tileX, tileY: tileY)
            // REFINERY completion should give the player a harvester if
            // they don't already have one — simplified port of
            // OpenDUNE's `House_EnsureHarvesterAvailable` (no carryall
            // ferry, direct spawn at the refinery's south exit).
            if type == 12 /* REFINERY */ {
                ensureHarvesterAvailable(
                    houseID: playerHouseID,
                    refineryTileX: tileX, refineryTileY: tileY,
                    host: host
                )
            }
            // Return the CYARD to IDLE now that its produced item is on
            // the map. Without this the yard stays stuck in READY and
            // sidebar clicks re-open placement for the same type.
            if let yardIdx = buildController.selectedYardIndex,
               yardIdx < host.structures.slots.count,
               host.structures.slots[yardIdx].isUsed
            {
                var yard = host.structures[yardIdx]
                if yard.state == Simulation.StructureState.ready.rawValue,
                   yard.objectType == UInt16(type)
                {
                    let priorState = yard.state
                    yard.state = Simulation.StructureState.idle.rawValue
                    yard.objectType = 0xFFFF
                    yard.countDown = 0
                    host.structures[yardIdx] = yard
                    Log.info(
                        "build-panel yard=\(yardIdx) state=\(priorState)→IDLE (produced \(type) committed)",
                        tracer: .label("build-panel")
                    )
                }
            }
            Log.info(
                "build-panel commit type=\(type) tile=(\(tileX),\(tileY)) → slot=\(idx)",
                tracer: .label("build-panel")
            )
            buildController.placementType = nil
            refreshBuildState()
            return .placementCommitted(
                type: type, slot: idx, tileX: tileX, tileY: tileY,
                degraded: validity < 0
            )
        }
        Log.info(
            "build-panel commit type=\(type) tile=(\(tileX),\(tileY)) FAILED (pool full)",
            tracer: .label("build-panel")
        )
        return .placementPoolFull(type: type, tileX: tileX, tileY: tileY)
    }

    /// Writes the freshly-placed structure's footprint tiles into the
    /// live `tileGrid` so subsequent landscape reads (validity, path,
    /// passability) AND the scene's per-tick ground-tile repaint see
    /// it.
    ///
    /// - **Slabs (type 0 / 1)**: `groundTileID = resolver.builtSlabTileID`,
    ///   no structure flag (slab is just concrete ground).
    /// - **Walls (type 14)**: `groundTileID = wallTileID + 1`, no
    ///   structure flag (walls live on the ground layer in OpenDUNE).
    /// - **Other structures**: paint the fully-built footprint using
    ///   the last `w × h` tiles of the iconGroup (matches
    ///   `ScenarioWorld` for scenario-spawned structures) and set
    ///   `hasStructure = true`.
    ///
    /// All cells get `houseID = playerHouseID` so the adjacency gate
    /// recognises them as player-owned.
    private func stampPlacement(type: UInt8, tileX: Int, tileY: Int) {
        let resolver = assets.tileResolver
        let iconMap = assets.iconMap
        let footprint = Simulation.Structures.footprintTiles(
            type: type, anchorX: tileX, anchorY: tileY
        )
        let isSlab = (type == 0 || type == 1)
        let isWall = (type == 14)

        // For non-slab / non-wall structures, pre-compute the
        // fully-built iconGroup tile IDs so the scene's ground-tile
        // pass can paint the building visually. Matches OpenDUNE's
        // `Structure_UpdateMap` offset (`src/structure.c:1796`):
        // skip the first two `layoutSize`-tile frames (construction
        // phases) and take the third as the finished frame. Falls
        // back to the tail for short groups.
        var iconTiles: [UInt16]? = nil
        if !isSlab, !isWall,
           let groupRaw = Simulation.StructureInfo.iconGroupRawValue(for: type),
           let group = Formats.IconMap.Group(rawValue: groupRaw),
           let info = Simulation.StructureInfo.lookup(type)
        {
            let all = iconMap.tileIds(in: group)
            let (w, h) = info.layout.dimensions
            let needed = w * h
            let start = 2 * needed
            if all.count >= start + needed {
                iconTiles = Array(all[start..<(start + needed)])
            } else if all.count >= needed {
                let tail = all.count - needed
                iconTiles = Array(all[tail..<(tail + needed)])
            }
        }

        let dims = Simulation.StructureInfo.lookup(type)?.layout.dimensions ?? (1, 1)

        for (fx, fy) in footprint {
            guard (0..<64).contains(fx), (0..<64).contains(fy) else { continue }
            let idx = fy * 64 + fx
            guard idx < tileGridRef.tiles.count else { continue }
            let old = tileGridRef.tiles[idx]
            var newGround = old.groundTileID
            var newHasStructure = old.hasStructure
            if isSlab {
                newGround = resolver.builtSlabTileID
            } else if isWall {
                newGround = resolver.wallTileID &+ 1
            } else {
                newHasStructure = true
                if let iconTiles {
                    let dx = fx - tileX
                    let dy = fy - tileY
                    let iconIdx = dy * dims.0 + dx
                    if iconIdx >= 0, iconIdx < iconTiles.count {
                        newGround = iconTiles[iconIdx]
                    }
                }
            }
            tileGridRef.tiles[idx] = Simulation.WorldSnapshot.Tile(
                groundTileID: newGround,
                overlayTileID: old.overlayTileID,
                houseID: playerHouseID,
                isUnveiled: old.isUnveiled,
                hasUnit: old.hasUnit,
                hasStructure: newHasStructure,
                hasAnimation: old.hasAnimation,
                hasExplosion: old.hasExplosion,
                objectRef: old.objectRef
            )
        }
        Log.info(
            "tile-stamp type=\(type) anchor=(\(tileX),\(tileY)) cells=\(footprint.count) slab=\(isSlab) wall=\(isWall) icons=\(iconTiles?.count ?? 0)",
            tracer: .label("tile")
        )
    }

    /// Simplified port of OpenDUNE's `House_EnsureHarvesterAvailable`
    /// (`src/house.c:298`). When a refinery finishes for `houseID`
    /// and the house doesn't already own a harvester (on-map or
    /// docked), spawn one at the refinery's south-exit tile.
    /// OpenDUNE ferries the harvester in via a spawned carryall; we
    /// shortcut to a direct spawn so the harvest AI can take over
    /// immediately. Logs under `harvester-spawn`.
    private func ensureHarvesterAvailable(
        houseID: UInt8,
        refineryTileX: Int, refineryTileY: Int,
        host: Scripting.Host
    ) {
        if Self.houseHasHarvester(houseID: houseID, pool: host.units) {
            Log.debug(
                "harvester-spawn skipped — house=\(houseID) already has a harvester",
                tracer: .label("harvester-spawn")
            )
            return
        }
        let exit = Simulation.Structures.factorySpawnTile(
            yardType: 12, anchorX: refineryTileX, anchorY: refineryTileY
        )
        var units = host.units
        guard let harvIdx = Simulation.Units.createUnit(
            type: 16 /* HARVESTER */, houseID: houseID,
            tileX: exit.x, tileY: exit.y, pool: &units
        ) else {
            Log.warning(
                "harvester-spawn FAILED — pool full (house=\(houseID))",
                tracer: .label("harvester-spawn")
            )
            return
        }
        // Action: HARVEST — so slice 7's idle-off-spice seek kicks in
        // on the next tickHarvesting pass and sends the harvester to
        // the nearest spice tile.
        var u = units[harvIdx]
        u.actionID = Simulation.ActionID.harvest
        units[harvIdx] = u
        host.units = units
        Log.info(
            "harvester-spawn house=\(houseID) slot=\(harvIdx) tile=(\(exit.x),\(exit.y)) action=HARVEST",
            tracer: .label("harvester-spawn")
        )
    }

    private static func houseHasHarvester(
        houseID: UInt8, pool: Simulation.UnitPool
    ) -> Bool {
        for idx in pool.findArray {
            let u = pool.slots[idx]
            if u.isUsed, u.type == 16, u.houseID == houseID { return true }
        }
        return false
    }

    private func autoSelectPlayerYard() {
        guard let host else { return }
        for idx in host.structures.findArray {
            let slot = host.structures.slots[idx]
            if slot.type == 8, slot.houseID == playerHouseID {
                buildController.selectedYardIndex = idx
                Log.info(
                    "build-panel auto-selected player CY slot=\(idx)",
                    tracer: .label("build-panel")
                )
                return
            }
        }
    }

    private static func isFactory(type: UInt8) -> Bool {
        switch type {
        case 3, 4, 5, 7, 10: return true
        default: return false
        }
    }

    // MARK: Static closure builders (shared with scene)

    private static func makeTileEnterScorer(
        ref: TileGridRef,
        resolver: TileResolver
    ) -> (UInt16, UInt8, Simulation.MovementType) -> Int32 {
        return { [ref] packed, orient8, movementType in
            guard Int(packed) < ref.tiles.count else { return 256 }
            let cell = ref.tiles[Int(packed)]
            let landscape = resolver.landscapeType(
                groundTileID: cell.groundTileID,
                overlayTileID: cell.overlayTileID,
                hasStructure: cell.hasStructure
            )
            let info = Simulation.LandscapeInfo.lookup(landscape)
            let mtIndex = Int(movementType.rawValue)
            guard mtIndex < info.movementSpeed.count else { return 256 }
            var speed = Int32(info.movementSpeed[mtIndex])
            if speed == 0 { return 256 }
            if (orient8 & 1) != 0 {
                speed -= speed / 4 + speed / 8
            }
            return Int32(UInt8(truncatingIfNeeded: UInt32(speed) ^ 0xFF))
        }
    }

    private static func makeLandscapeLookup(
        ref: TileGridRef,
        resolver: TileResolver
    ) -> (UInt16) -> UInt8 {
        return { [ref] packed in
            guard Int(packed) < ref.tiles.count else { return 0 }
            let cell = ref.tiles[Int(packed)]
            let landscape = resolver.landscapeType(
                groundTileID: cell.groundTileID,
                overlayTileID: cell.overlayTileID,
                hasStructure: cell.hasStructure
            )
            return UInt8(truncatingIfNeeded: landscape.rawValue)
        }
    }

    /// Builds the `spiceLevelDidChange` closure wired into
    /// `Scripting.Host` — on every level transition, runs a port of
    /// OpenDUNE's `Map_FixupSpiceEdges` (`src/map.c:725..764`) over
    /// the changed tile AND its 4 cardinal neighbours. Each spice tile
    /// picks one of 16 edge-fitted variants via the 4-neighbour
    /// bitfield stored on `SpiceMap`; a fully-drained tile reverts to
    /// plain sand (landscape offset 0). Without this, depleted patches
    /// render every surviving spice cell as the "isolated" no-neighbour
    /// variant — hard blocky edges against sand.
    ///
    /// Neighbours also get rewritten because their bitfield variant
    /// shifts when the centre cell flips level (e.g. draining one cell
    /// leaves its surviving northern neighbour with one fewer matching
    /// side, so it should drop to a different edge sprite).
    private static func makeSpiceRepaint(
        ref: TileGridRef,
        resolver: TileResolver
    ) -> (UInt16, Simulation.SpiceMap.Level, Simulation.SpiceMap) -> Void {
        let iconMap = resolver.iconMap
        let sandID = iconMap.tileId(in: .landscape, offset: 0)
        func spriteID(at packed: UInt16, map: Simulation.SpiceMap) -> UInt16 {
            let level = map[packed]
            switch level {
            case .bare, .notSand:
                return sandID
            case .thin:
                let bits = map.edgeBitfield(at: packed) ?? 0
                return iconMap.tileId(in: .landscape, offset: 49 + Int(bits))
            case .thick:
                let bits = map.edgeBitfield(at: packed) ?? 0
                return iconMap.tileId(in: .landscape, offset: 65 + Int(bits))
            }
        }
        func rewrite(idx: Int, newID: UInt16) {
            let old = ref.tiles[idx]
            if old.groundTileID == newID { return }
            ref.tiles[idx] = Simulation.WorldSnapshot.Tile(
                groundTileID: newID,
                overlayTileID: old.overlayTileID,
                houseID: old.houseID,
                isUnveiled: old.isUnveiled,
                hasUnit: old.hasUnit,
                hasStructure: old.hasStructure,
                hasAnimation: old.hasAnimation,
                hasExplosion: old.hasExplosion,
                objectRef: old.objectRef
            )
        }
        return { [ref] packed, _, map in
            let idx = Int(packed)
            guard idx < ref.tiles.count else { return }
            rewrite(idx: idx, newID: spriteID(at: packed, map: map))
            let x = idx % Simulation.SpiceMap.width
            let y = idx / Simulation.SpiceMap.width
            let neighbours: [(Int, Int)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
            for (dx, dy) in neighbours {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < Simulation.SpiceMap.width,
                      ny >= 0, ny < Simulation.SpiceMap.height else { continue }
                let nIdx = ny * Simulation.SpiceMap.width + nx
                let nPacked = UInt16(nIdx)
                let nLevel = map[nPacked]
                guard nLevel == .thin || nLevel == .thick else { continue }
                rewrite(idx: nIdx, newID: spriteID(at: nPacked, map: map))
            }
        }
    }

    /// Slice: spice-bloom. Hands the scheduler a writer into the
    /// live tileGrid so `Bloom.explodeSpice` can reset the bloom
    /// cell's `groundTileID` back to sand after detonation.
    private static func makeGroundTileOverride(
        ref: TileGridRef
    ) -> (UInt16, UInt16) -> Void {
        return { [ref] packed, tileID in
            let idx = Int(packed)
            guard idx < ref.tiles.count else { return }
            let old = ref.tiles[idx]
            if old.groundTileID == tileID { return }
            ref.tiles[idx] = Simulation.WorldSnapshot.Tile(
                groundTileID: tileID,
                overlayTileID: old.overlayTileID,
                houseID: old.houseID,
                isUnveiled: old.isUnveiled,
                hasUnit: old.hasUnit,
                hasStructure: old.hasStructure,
                hasAnimation: old.hasAnimation,
                hasExplosion: old.hasExplosion,
                objectRef: old.objectRef
            )
        }
    }

    private static func makeSpiceMap(
        snapshot: Simulation.WorldSnapshot,
        resolver: TileResolver
    ) -> Simulation.SpiceMap {
        let tiles = snapshot.tiles
        return Simulation.SpiceMap { i in
            let cell = tiles[i]
            return resolver.landscapeType(
                groundTileID: cell.groundTileID,
                overlayTileID: cell.overlayTileID,
                hasStructure: cell.hasStructure
            )
        }
    }
}
