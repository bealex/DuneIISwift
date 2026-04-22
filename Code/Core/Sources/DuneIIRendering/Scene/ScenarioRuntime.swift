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
    /// Live tile grid. Held in a class box so closures captured by the
    /// scheduler's `landscapeAt` + `tileEnterScore` see runtime
    /// mutations (placed slabs, new structures) without being rebuilt.
    private let tileGridRef = TileGridRef()
    public var tileGrid: [Simulation.WorldSnapshot.Tile] { tileGridRef.tiles }
    public private(set) var tickCounter: Int = 0
    public private(set) var currentYardKind: YardKind = .structure
    public private(set) var scenarioName: String?

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
        // Stamp every scenario-spawned structure's footprint with
        // `hasStructure = true` + the owner's houseID so the
        // pathfinder + passability gate see them as impassable. The
        // plain `Map.Generator` used by `WorldSnapshot.init(scenario:)`
        // doesn't apply structure placements (that's ScenarioWorld's
        // job, which we only use for rendering).
        for idx in snapshot.structures.findArray {
            let s = snapshot.structures.slots[idx]
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            for (fx, fy) in footprint {
                guard (0..<64).contains(fx), (0..<64).contains(fy) else { continue }
                let cellIdx = fy * 64 + fx
                guard cellIdx < tileGridRef.tiles.count else { continue }
                let old = tileGridRef.tiles[cellIdx]
                tileGridRef.tiles[cellIdx] = Simulation.WorldSnapshot.Tile(
                    groundTileID: old.groundTileID,
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
            spiceMap: spiceMap
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
        scheduler = Simulation.Scheduler(
            host: host,
            unitVM: unitVM,
            structureVM: structureVM,
            teamVM: teamVM,
            harvestRNG: harvestRNG
        )
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

    // MARK: Click intent

    @discardableResult
    public func leftClick(tileX: Int, tileY: Int) -> ClickOutcome {
        guard let host else { return .none }

        // 1. Unit-command first (when not mid-placement).
        if buildController.placementType == nil {
            let action = commandController.handle(
                click: .leftMapTile(x: tileX, y: tileY),
                pool: host.units,
                playerHouseID: playerHouseID
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
            case .orderAttackStructure:
                // Left-click never produces this case (structure
                // attacks are right-click only); handle defensively.
                break
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
        // to the build-panel placeholder branch.
        if let selIdx = selectedStructureIndex {
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
        // pass can paint the building visually.
        var iconTiles: [UInt16]? = nil
        if !isSlab, !isWall,
           let groupRaw = Simulation.StructureInfo.iconGroupRawValue(for: type),
           let group = Formats.IconMap.Group(rawValue: groupRaw),
           let info = Simulation.StructureInfo.lookup(type)
        {
            let all = iconMap.tileIds(in: group)
            let (w, h) = info.layout.dimensions
            let needed = w * h
            if all.count >= needed {
                let start = all.count - needed
                iconTiles = Array(all[start..<(start + needed)])
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
