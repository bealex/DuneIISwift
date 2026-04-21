import Foundation
import AppKit
import SpriteKit
import DuneIICore
import Memoirs

/// P3 scenario walker + P4 tick-loop kickoff. Loads an `SCEN?00?.INI`
/// from the install, stamps the scenario map via `ScenarioWorld`, and
/// renders the 64×64 tile grid as `SKSpriteNode`s. Unit and structure
/// spawns are drawn as house-coloured marker nodes (circles for units,
/// rectangles for structures).
///
/// P4 tick loop: builds a live `Simulation.WorldSnapshot` + `Scheduler`
/// from the scenario and calls `scheduler.tick()` every 5 frames (≈12 Hz
/// at 60 fps, matching OpenDUNE's `Timer_GameLoop` cadence). Scripts halt
/// immediately on any `SCRIPT_FUNCTION` opcode since the per-slot
/// function tables are currently empty — but the loop itself runs,
/// proving the scenario → snapshot → host → scheduler → VM wiring.
@MainActor
public final class ScenarioScene: SKScene {
    public static let tileSize: CGFloat = 16.0
    /// 1 tick per 5 `update(_:)` calls. Matches OpenDUNE's main-loop
    /// script cadence.
    public static let framesPerTick = 5
    /// 64 tiles × tileSize = map extent; also the left boundary of the
    /// build-panel sidebar.
    public static let mapSize: CGFloat = tileSize * 64
    /// Right-hand sidebar for the build panel (P5 slice 3).
    public static let sidebarWidth: CGFloat = 128
    /// One row per buildable option; fits a 32×32 icon + 1pt outline.
    public static let sidebarRowHeight: CGFloat = 32
    public static let sidebarPadding: CGFloat = 4

    public weak var coordinator: SceneCoordinator?
    private let assets: AssetLoader
    private let scenarioName: String
    private var tileNodes: [SKSpriteNode] = []

    /// Cached ICN tile → `SKTexture`. Built lazily from `assets.loadIcn()`.
    private var tileTextures: [SKTexture] = []

    // P4 tick state.
    private var scheduler: Simulation.Scheduler?
    private var frameCounter: Int = 0
    private var tickCounter: Int = 0
    private var hud: SKLabelNode?
    /// Per-unit-pool-slot marker nodes, keyed by pool index. `nil` slots
    /// are unallocated (or freed). Rebuilt at scene build; positions /
    /// textures are refreshed every tick by `syncVisualsFromPool()`.
    private var unitMarkers: [Int: SKSpriteNode] = [:]
    private var structureMarkers: [Int: SKShapeNode] = [:]
    /// Explosion visuals — one disc per active `ExplosionPool` slot.
    /// Created lazily on first observation; removed when the slot frees.
    private var explosionMarkers: [Int: SKShapeNode] = [:]
    /// Atlas mapping `groundSpriteID` → `SKTexture` for every unit frame
    /// across UNITS2.SHP / UNITS1.SHP / UNITS.SHP. Loaded once per scene.
    private var unitAtlas: UnitSpriteAtlas?
    /// Fallback texture used when a unit's resolved sprite ID is out of
    /// the atlas range (e.g. `displayMode == .singleFrame`).
    private var fallbackMarkerTexture: SKTexture?

    // P5 slice 3 — build panel.
    private var buildController = BuildPanelController()
    /// Container for sidebar slot nodes. Always parented to the scene;
    /// children are rebuilt on every `refreshBuildSidebar()`.
    private var sidebarNode: SKNode?
    /// Player identity — also drives `Scripting.Host.playerHouseID`.
    /// Hardcoded to Atreides for P3/P5; wired through the controller
    /// once campaign select exists.
    private let playerHouseID: UInt8 = Simulation.House.atreides
    /// Snapshot-time tile grid captured at scene build; consulted by
    /// the landscape gate inside `commitPlacement`. Doesn't track
    /// placements made during play — pool overlap is authoritative for
    /// newly-built structures. Slice 4b.
    private var tileGrid: [Simulation.WorldSnapshot.Tile] = []

    public init(assets: AssetLoader, scenarioName: String) {
        self.assets = assets
        self.scenarioName = scenarioName
        let size = CGSize(width: Self.mapSize + Self.sidebarWidth, height: Self.mapSize)
        super.init(size: size)
        scaleMode = .aspectFit
        backgroundColor = .black
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func didMove(to view: SKView) {
        removeAllChildren()
        tileNodes.removeAll(keepingCapacity: true)
        unitMarkers.removeAll(keepingCapacity: true)
        structureMarkers.removeAll(keepingCapacity: true)
        explosionMarkers.removeAll(keepingCapacity: true)
        scheduler = nil
        frameCounter = 0
        tickCounter = 0
        do {
            try build()
        } catch {
            let label = SKLabelNode(text: "\(scenarioName): \(error)")
            label.fontColor = .red
            label.fontSize = 12
            label.position = CGPoint(x: size.width / 2, y: size.height / 2)
            addChild(label)
        }
    }

    public override func update(_ currentTime: TimeInterval) {
        guard scheduler != nil else { return }
        frameCounter += 1
        if frameCounter >= Self.framesPerTick {
            frameCounter = 0
            scheduler?.tick()
            tickCounter += 1
            syncVisualsFromPool()
            refreshHud()
            // Every 60 ticks (≈5 seconds at 12 Hz), sample the first
            // few unit slots so we can see whether position /
            // orientation are actually changing run-over-run.
            if tickCounter % 60 == 0, let host = scheduler?.host {
                let sample = host.units.findArray.prefix(4)
                let lines = sample.map { idx -> String in
                    let s = host.units.slots[idx]
                    return "u\(idx)(t=\(s.type) h=\(s.houseID) a=\(s.actionID) o=\(s.orientationCurrent) pos=(\(s.positionX),\(s.positionY)) dst=\(String(format: "0x%04X", s.targetMove)))"
                }.joined(separator: " | ")
                Log.info("tick \(tickCounter): \(lines)", tracer: .label("scene-tick"))
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        let click = classifyClick(at: location)
        let action = buildController.handle(click: click)
        switch action {
        case .enterPlacement(let type):
            Log.info(
                "build-panel: enter placement type=\(type)",
                tracer: .label("build-panel")
            )
            refreshBuildSidebar()
        case .commitPlacement(let type, let tileX, let tileY):
            commitPlacement(type: type, tileX: tileX, tileY: tileY)
        case .none:
            // Sidebar click on empty row / outside click → fall back to
            // the pre-slice-3 "return to main menu" behaviour, but only
            // when we're *not* mid-placement (otherwise a misclick
            // outside the sidebar would bail out of placement silently).
            if buildController.placementType == nil {
                coordinator?.route(to: .mainMenu)
            }
        }
    }

    /// Pure translation from a scene-local point to a controller click.
    private func classifyClick(at p: CGPoint) -> BuildPanelController.Click {
        if p.x >= Self.mapSize {
            if let index = sidebarSlotIndex(atY: p.y) {
                return .sidebarSlot(index: index)
            }
            return .outside
        }
        let tileX = Int(p.x / Self.tileSize)
        // Scene origin is bottom-left; our map indexing is top-left.
        let tileY = 63 - Int(p.y / Self.tileSize)
        guard (0..<64).contains(tileX), (0..<64).contains(tileY) else {
            return .outside
        }
        return .mapTile(x: tileX, y: tileY)
    }

    // MARK: - Private helpers

    private enum BuildError: Error, CustomStringConvertible {
        case scenarioNotFound(String)

        var description: String {
            switch self {
            case .scenarioNotFound(let n): return "scenario \(n) not in install"
            }
        }
    }

    private func build() throws {
        Log.info("ScenarioScene.build(\(scenarioName))", tracer: .label("scene"))
        guard let scenario = try assets.loadScenario(named: scenarioName) else {
            throw BuildError.scenarioNotFound(scenarioName)
        }
        tileTextures = try assets.loadIcn().map {
            let t = SKTexture(cgImage: $0)
            t.filteringMode = .nearest
            return t
        }

        let resolver = assets.tileResolver
        let world = ScenarioWorld(
            scenario: scenario,
            resolver: resolver,
            iconMap: assets.iconMap
        )

        unitAtlas = try? UnitSpriteAtlas(loader: assets)
        fallbackMarkerTexture = Self.makeFallbackTexture()

        addGroundTiles(world: world)
        try setUpScheduler(scenario: scenario, resolver: resolver)
        // Markers are created lazily on observation of live pool slots,
        // so dynamically-spawned bullets and post-spawn units get
        // visuals without pre-seeding. See `syncVisualsFromPool`.
        syncVisualsFromPool()

        let banner = SKLabelNode(text: "\(scenarioName) · click elsewhere to return")
        banner.fontColor = .white
        banner.fontSize = 14
        banner.position = CGPoint(x: Self.mapSize / 2, y: size.height - 16)
        banner.horizontalAlignmentMode = .center
        banner.zPosition = 10
        addChild(banner)

        addHud()
        autoSelectPlayerYard()
        refreshBuildSidebar()
    }

    /// Builds a live `Simulation.WorldSnapshot` from the scenario spawns,
    /// wraps the pools in a `Scripting.Host`, and wires a `Scheduler` with
    /// the install's `UNIT.EMC` / `BUILD.EMC` programs (empty function
    /// tables — scripts halt on first `FUNCTION` opcode; that's expected).
    private func setUpScheduler(scenario: Scenario, resolver: TileResolver) throws {
        let snapshot = try Simulation.WorldSnapshot(scenario: scenario, resolver: resolver)
        tileGrid = snapshot.tiles
        let scorer = Self.makeTileEnterScorer(snapshot: snapshot, resolver: resolver)
        let host = Scripting.Host(
            units: snapshot.units,
            structures: snapshot.structures,
            explosions: Simulation.ExplosionPool(),
            teams: snapshot.teams,
            currentObject: nil,
            texts: [],
            textLog: [],
            voiceLog: [],
            tileEnterScore: scorer,
            playerHouseID: Simulation.House.atreides
        )

        // RNG stream shared between host-function closures (mirrors
        // OpenDUNE's one-global-LCG model). Seed by the scenario's map
        // seed so runs are reproducible on replay.
        let source = Scripting.RandomSource(
            lcgSeed: UInt16(truncatingIfNeeded: scenario.mapField.seed),
            toolsSeed: scenario.mapField.seed
        )
        let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
        let structureFunctions = Scripting.Functions.structureTable(host: host, source: source)

        let unitProgram = ((try? assets.loadEmc(named: "UNIT.EMC")) ?? nil) ?? Formats.Emc.Program.empty
        let structureProgram = ((try? assets.loadEmc(named: "BUILD.EMC")) ?? nil) ?? Formats.Emc.Program.empty
        let teamProgram = ((try? assets.loadEmc(named: "TEAM.EMC")) ?? nil) ?? Formats.Emc.Program.empty

        Log.info(
            "EMC loaded: UNIT.EMC code=\(unitProgram.code.count)w ep=\(unitProgram.entryPoints.count), BUILD.EMC code=\(structureProgram.code.count)w ep=\(structureProgram.entryPoints.count), TEAM.EMC code=\(teamProgram.code.count)w ep=\(teamProgram.entryPoints.count)",
            tracer: .label("scene")
        )

        let teamFunctions = Scripting.Functions.teamTable(host: host, source: source)
        let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
        let structureVM = Scripting.VM(program: structureProgram, functions: structureFunctions)
        let teamVM = Scripting.VM(program: teamProgram, functions: teamFunctions)

        scheduler = Simulation.Scheduler(
            host: host, unitVM: unitVM, structureVM: structureVM, teamVM: teamVM
        )
    }

    private func addHud() {
        let label = SKLabelNode(text: "Tick 0")
        label.fontColor = .white
        label.fontSize = 12
        label.position = CGPoint(x: 12, y: size.height - 16)
        label.horizontalAlignmentMode = .left
        label.zPosition = 10
        addChild(label)
        hud = label
        refreshHud()
    }

    private func refreshHud() {
        guard let hud else { return }
        let units = scheduler?.host.units.findArray.count ?? 0
        let structures = scheduler?.host.structures.findArray.count ?? 0
        hud.text = "Tick \(tickCounter) · units \(units) · structures \(structures)"
    }

    private func addGroundTiles(world: ScenarioWorld) {
        for y in 0..<64 {
            for x in 0..<64 {
                let cell = world.map[x, y]
                let tileID = cell.groundTileID
                guard Int(tileID) < tileTextures.count else { continue }
                let node = SKSpriteNode(texture: tileTextures[Int(tileID)])
                node.size = CGSize(width: Self.tileSize, height: Self.tileSize)
                node.anchorPoint = .zero
                node.position = screenPosition(x: x, y: y)
                node.zPosition = 0
                addChild(node)
                tileNodes.append(node)
            }
        }
    }

    /// Per-tick sync — reads live pool state, lazy-creates markers for
    /// newly-allocated slots (e.g. bullets spawned mid-combat), updates
    /// positions / textures / flip, and hides or recycles markers when
    /// slots free. Also drives explosion visuals from `ExplosionPool`.
    private func syncVisualsFromPool() {
        guard let host = scheduler?.host else { return }
        syncUnits(host: host)
        syncStructures(host: host)
        syncExplosions(host: host)
    }

    private func syncUnits(host: Scripting.Host) {
        for idx in 0..<host.units.slots.count {
            let slot = host.units.slots[idx]
            guard slot.isUsed else {
                // Hide any marker previously associated with this slot.
                unitMarkers[idx]?.isHidden = true
                continue
            }
            let marker = unitMarkers[idx] ?? makeUnitMarker()
            unitMarkers[idx] = marker
            marker.isHidden = false
            // Let the per-house palette remap do the colouring — no
            // blend-factor tint on top. Previously we painted a 35%
            // house-colour overlay because sprites all rendered with
            // Harkonnen's red. Now that `loadShp(named:houseID:)`
            // produces real per-house frames, the overlay would fight
            // with the palette remap and produce muddy colours.
            marker.colorBlendFactor = 0
            marker.position = screenPositionPos32(x: slot.positionX, y: slot.positionY)
            if let info = Simulation.UnitInfo.lookup(slot.type) {
                let frame = UnitSpriteAtlas.resolveFrame(info: info, orientation: slot.orientationCurrent)
                let texture = unitAtlas?.texture(at: frame.spriteID, houseID: slot.houseID)
                    ?? fallbackMarkerTexture
                marker.texture = texture
                if let size = texture?.size() {
                    let maxDim = max(size.width, size.height)
                    let scale = Self.tileSize / max(maxDim, 1)
                    marker.size = CGSize(width: size.width * scale, height: size.height * scale)
                }
                marker.xScale = abs(marker.xScale) * (frame.flipHorizontal ? -1 : 1)
            }
        }
    }

    private func makeUnitMarker() -> SKSpriteNode {
        let marker = SKSpriteNode()
        marker.size = CGSize(width: Self.tileSize, height: Self.tileSize)
        marker.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        marker.zPosition = 2
        addChild(marker)
        return marker
    }

    private func syncStructures(host: Scripting.Host) {
        // Structures are now rendered via the baseline tile stamp
        // (ScenarioWorld paints the fully-built iconGroup tiles under
        // each structure footprint). All we need here is a thin
        // house-colour outline so the player can tell who owns what —
        // keep the outline only, no fill overlay. Freed slots hide.
        for idx in 0..<host.structures.slots.count {
            let slot = host.structures.slots[idx]
            guard slot.isUsed, idx < Simulation.StructurePool.capacitySoft else {
                structureMarkers[idx]?.isHidden = true
                continue
            }
            let dims = Simulation.StructureInfo.lookup(slot.type)?.layout.dimensions ?? (2, 2)
            let marker: SKShapeNode
            if let existing = structureMarkers[idx] {
                marker = existing
                marker.isHidden = false
            } else {
                marker = SKShapeNode(rectOf: CGSize(
                    width: Self.tileSize * CGFloat(dims.0),
                    height: Self.tileSize * CGFloat(dims.1)
                ))
                marker.fillColor = .clear
                marker.lineWidth = 1
                marker.zPosition = 1
                addChild(marker)
                structureMarkers[idx] = marker
            }
            marker.strokeColor = houseColorFor(houseID: slot.houseID).withAlphaComponent(0.8)
            let centeredX = Int32(slot.positionX) + Int32(dims.0 - 1) * 128
            let centeredY = Int32(slot.positionY) + Int32(dims.1 - 1) * 128
            marker.position = screenPositionPos32(
                x: UInt16(clamping: centeredX),
                y: UInt16(clamping: centeredY)
            )
        }
    }

    /// One small coloured disc per active explosion slot. Position comes
    /// from the slot; fade and removal come from the scheduler's
    /// `tickExplosions` freeing the slot.
    private func syncExplosions(host: Scripting.Host) {
        for idx in 0..<host.explosions.slots.count {
            let slot = host.explosions.slots[idx]
            if !slot.isActive {
                explosionMarkers[idx]?.removeFromParent()
                explosionMarkers[idx] = nil
                continue
            }
            let marker = explosionMarkers[idx] ?? makeExplosionMarker(for: slot)
            if explosionMarkers[idx] == nil {
                explosionMarkers[idx] = marker
                addChild(marker)
            }
            marker.position = screenPositionPos32(x: slot.positionX, y: slot.positionY)
            // Simple lifetime fade: alpha falls as `remainingFrames → 0`.
            let frames = max(Double(slot.remainingFrames), 1)
            marker.alpha = CGFloat(min(1.0, frames / 30.0))
        }
    }

    private func makeExplosionMarker(for slot: Simulation.ExplosionSlot) -> SKShapeNode {
        let marker = SKShapeNode(circleOfRadius: Self.tileSize * 0.5)
        marker.lineWidth = 0
        marker.zPosition = 3
        marker.fillColor = explosionColor(for: slot.type)
        marker.alpha = 0.9
        return marker
    }

    /// Rough per-type palette — enough to visually distinguish missile
    /// blasts from bullet impacts without needing the real SHP anim.
    private func explosionColor(for type: UInt16) -> NSColor {
        switch type {
        case Simulation.ExplosionType.impactSmall.rawValue:
            return NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.4, alpha: 1)
        case Simulation.ExplosionType.impactMedium.rawValue,
             Simulation.ExplosionType.impactLarge.rawValue,
             Simulation.ExplosionType.impactExplode.rawValue:
            return NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.1, alpha: 1)
        case Simulation.ExplosionType.deathHand.rawValue:
            return NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.2, alpha: 1)
        case Simulation.ExplosionType.deviatorGas.rawValue:
            return NSColor(calibratedRed: 0.5, green: 1.0, blue: 0.4, alpha: 1)
        case Simulation.ExplosionType.sandwormSwallow.rawValue:
            return NSColor(calibratedRed: 0.6, green: 0.4, blue: 0.2, alpha: 1)
        default:
            return NSColor(calibratedWhite: 0.9, alpha: 1)
        }
    }

    /// Convert a pos32 (pixel-scale, each tile = 256 pixels) to an
    /// SKScene point (each tile = `tileSize` points, y-flipped because
    /// SpriteKit is bottom-left but the map is top-left).
    private func screenPositionPos32(x: UInt16, y: UInt16) -> CGPoint {
        let tileX = CGFloat(x) / 256.0
        let tileY = CGFloat(y) / 256.0
        let flippedY = 64 - tileY
        return CGPoint(x: tileX * Self.tileSize, y: flippedY * Self.tileSize)
    }

    /// Map grid origin is top-left; SpriteKit's is bottom-left. Flip y and
    /// multiply by tile size.
    private func screenPosition(x: Int, y: Int) -> CGPoint {
        let flippedY = 63 - y
        return CGPoint(x: CGFloat(x) * Self.tileSize, y: CGFloat(flippedY) * Self.tileSize)
    }

    /// Map-backed `tileEnterScore` closure. Reads the snapshot's tile
    /// grid at the packed index, classifies via `TileResolver`, and
    /// returns the OpenDUNE-faithful score (inverted speed or `256` for
    /// impassable). See `Unit_GetTileEnterScore` in `src/unit.c:2335`.
    private static func makeTileEnterScorer(
        snapshot: Simulation.WorldSnapshot,
        resolver: TileResolver
    ) -> (UInt16, UInt8, Simulation.MovementType) -> Int32 {
        // Capture tiles so the closure is self-contained.
        let tiles = snapshot.tiles
        return { packed, orient8, movementType in
            guard Int(packed) < tiles.count else { return 256 }
            let cell = tiles[Int(packed)]
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
            // Diagonal tax — `(orient8 & 1) != 0` means NE/SE/SW/NW.
            if (orient8 & 1) != 0 {
                speed -= speed / 4 + speed / 8
            }
            // Invert: higher speed ⇒ lower cost.
            return Int32(UInt8(truncatingIfNeeded: UInt32(speed) ^ 0xFF))
        }
    }

    /// 8×8 white square used when a unit's resolved sprite ID is out of
    /// the atlas range. Keeps the marker visible as a fallback rather
    /// than invisible.
    private static func makeFallbackTexture() -> SKTexture {
        let size = CGSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tx = SKTexture(image: image)
        tx.filteringMode = .nearest
        return tx
    }

    // MARK: - Build panel (P5 slice 3)

    /// Scans the structure pool for the first CONSTRUCTION_YARD (type 8)
    /// owned by the player. Called once after scene build; slice 4 adds
    /// click-to-switch between multiple yards.
    private func autoSelectPlayerYard() {
        guard let host = scheduler?.host else { return }
        for idx in host.structures.findArray {
            let slot = host.structures.slots[idx]
            if slot.type == 8, slot.houseID == playerHouseID {
                buildController.selectedYardIndex = idx
                Log.info(
                    "build-panel: auto-selected player construction yard slot=\(idx)",
                    tracer: .label("build-panel")
                )
                return
            }
        }
    }

    /// Recomputes the buildable bitmask from the selected yard + current
    /// pool state, updates the controller, and rebuilds sidebar sprites.
    /// Called once at scene build and after every commit.
    private func refreshBuildSidebar() {
        guard let host = scheduler?.host,
              let yardIdx = buildController.selectedYardIndex,
              yardIdx < host.structures.slots.count,
              host.structures.slots[yardIdx].isUsed
        else {
            buildController.refreshAvailableTypes([])
            renderSidebar()
            return
        }
        let yard = host.structures.slots[yardIdx]
        let built = Simulation.Structures.structuresBuilt(
            houseID: yard.houseID, pool: host.structures
        )
        // campaignID is 0-indexed for OpenDUNE; hardcode to 0 (mission 1)
        // until a campaign-progress field exists on ScenarioScene.
        let campaignID: UInt16 = 0
        let mask = Simulation.Structures.buildableStructuresFromYard(
            yardHouseID: yard.houseID,
            yardUpgradeLevel: yard.upgradeLevel,
            structuresBuilt: built,
            campaignID: campaignID,
            playerHouseID: playerHouseID
        )
        let types = Simulation.StructureInfo.buildableTypesByPriority(from: mask)
        buildController.refreshAvailableTypes(types)
        renderSidebar()
    }

    /// Tears down + rebuilds the sidebar node stack. Each slot is a
    /// 32×32 icon from the structure's iconGroup, with a 1pt outline.
    /// The slot currently being placed gets a brighter outline.
    private func renderSidebar() {
        sidebarNode?.removeFromParent()
        let container = SKNode()
        container.zPosition = 20
        addChild(container)
        sidebarNode = container

        // Background panel so the sidebar reads as a distinct region.
        let bgSize = CGSize(width: Self.sidebarWidth, height: Self.mapSize)
        let bg = SKShapeNode(rect: CGRect(
            x: Self.mapSize, y: 0,
            width: bgSize.width, height: bgSize.height
        ))
        bg.fillColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        bg.strokeColor = NSColor(calibratedWhite: 0.25, alpha: 1.0)
        bg.lineWidth = 1
        container.addChild(bg)

        let header = SKLabelNode(text: "BUILD")
        header.fontColor = .white
        header.fontSize = 11
        header.fontName = "Menlo-Bold"
        header.horizontalAlignmentMode = .center
        header.position = CGPoint(
            x: Self.mapSize + Self.sidebarWidth / 2,
            y: Self.mapSize - 18
        )
        container.addChild(header)

        let iconMap = assets.iconMap
        for (row, type) in buildController.availableTypes.enumerated() {
            let slotY = sidebarSlotY(forIndex: row)
            let slotFrame = CGRect(
                x: Self.mapSize + Self.sidebarPadding,
                y: slotY,
                width: Self.sidebarWidth - 2 * Self.sidebarPadding,
                height: Self.sidebarRowHeight - Self.sidebarPadding
            )
            let slotNode = SKShapeNode(rect: slotFrame)
            slotNode.fillColor = NSColor(calibratedWhite: 0.18, alpha: 1.0)
            let isSelected = (buildController.placementType == type)
            slotNode.strokeColor = isSelected
                ? NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 1)
                : NSColor(calibratedWhite: 0.35, alpha: 1.0)
            slotNode.lineWidth = isSelected ? 2 : 1
            container.addChild(slotNode)

            // Icon — last tile of the iconGroup (fully-built frame).
            if let groupRaw = Simulation.StructureInfo.iconGroupRawValue(for: type),
               let group = Formats.IconMap.Group(rawValue: groupRaw) {
                let tileIds = iconMap.tileIds(in: group)
                if let chosenTileID = tileIds.last, Int(chosenTileID) < tileTextures.count {
                    let texture = tileTextures[Int(chosenTileID)]
                    let icon = SKSpriteNode(texture: texture)
                    icon.size = CGSize(width: 24, height: 24)
                    icon.position = CGPoint(
                        x: slotFrame.minX + 16,
                        y: slotFrame.midY
                    )
                    container.addChild(icon)
                }
            }

            // Label: abbreviated type name. Helps when the icon is tiny.
            let label = SKLabelNode(text: Self.shortName(for: type))
            label.fontColor = .white
            label.fontSize = 10
            label.fontName = "Menlo"
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.position = CGPoint(
                x: slotFrame.minX + 34,
                y: slotFrame.midY
            )
            container.addChild(label)
        }
    }

    /// Top-to-bottom sidebar row placement. Row 0 lives just below the
    /// "BUILD" header; each subsequent row is `sidebarRowHeight` lower.
    private func sidebarSlotY(forIndex row: Int) -> CGFloat {
        let topMargin: CGFloat = 36
        let topY = Self.mapSize - topMargin
        return topY - CGFloat(row + 1) * Self.sidebarRowHeight
    }

    /// Inverse of `sidebarSlotY`: given a scene-local Y, returns the
    /// row index that contains it, or nil when outside any row.
    private func sidebarSlotIndex(atY y: CGFloat) -> Int? {
        let topMargin: CGFloat = 36
        let topY = Self.mapSize - topMargin
        let rawRow = (topY - y) / Self.sidebarRowHeight
        let row = Int(rawRow) - 1
        guard row >= 0, row < buildController.availableTypes.count else { return nil }
        return row
    }

    /// Commits a placement: validates via `isValidBuildLocation`, then
    /// maps tile coords to pos32, invokes `Simulation.Structures.create`,
    /// refreshes the sidebar, and logs the outcome. Slice 4a rejects
    /// out-of-bounds + overlapping placements; slice 4b adds the
    /// landscape gate + slab-deficit count. Slice 4c will apply HP
    /// degradation for `-neededSlabs` returns.
    private func commitPlacement(type: UInt8, tileX: Int, tileY: Int) {
        guard let host = scheduler?.host else { return }
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
        let validity = Simulation.Structures.isValidBuildLocation(
            tileX: tileX, tileY: tileY, type: type,
            structures: host.structures, units: host.units,
            landscapeAt: landscapeAt
        )
        guard validity != 0 else {
            Log.info(
                "build-panel: commit rejected — invalid tile=(\(tileX),\(tileY)) type=\(type)",
                tracer: .label("build-panel")
            )
            // Reset placement state on rejection so a re-pick starts
            // cleanly. Sidebar refresh clears the highlight.
            buildController.placementType = nil
            refreshBuildSidebar()
            return
        }
        if validity < 0 {
            // Valid but degraded — slab deficit = -validity. Logged so
            // the user (and slice 4c) can see it; HP stays at max for
            // now.
            Log.info(
                "build-panel: commit degraded tile=(\(tileX),\(tileY)) type=\(type) slabs_needed=\(-validity)",
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
            pool: &pool
        )
        host.structures = pool
        if let idx {
            Log.info(
                "build-panel: commit type=\(type) tile=(\(tileX),\(tileY)) → slot=\(idx)",
                tracer: .label("build-panel")
            )
        } else {
            Log.info(
                "build-panel: commit type=\(type) tile=(\(tileX),\(tileY)) FAILED (pool full)",
                tracer: .label("build-panel")
            )
        }
        refreshBuildSidebar()
    }

    /// Short name for sidebar labels. Mirrors in-game abbreviations
    /// without depending on the string-table assets.
    private static func shortName(for type: UInt8) -> String {
        switch type {
        case 0:  return "Slab 1"
        case 1:  return "Slab 4"
        case 2:  return "Palace"
        case 3:  return "Light"
        case 4:  return "Heavy"
        case 5:  return "Hi-Tech"
        case 6:  return "IX"
        case 7:  return "WOR"
        case 8:  return "C-Yard"
        case 9:  return "Wndtrp"
        case 10: return "Barr."
        case 11: return "Spcprt"
        case 12: return "Refin."
        case 13: return "Repair"
        case 14: return "Wall"
        case 15: return "Turret"
        case 16: return "R-Turr"
        case 17: return "Silo"
        case 18: return "Outpst"
        default: return "?"
        }
    }

    /// House ID → colour; falls back to white for unknown IDs.
    private func houseColorFor(houseID: UInt8) -> NSColor {
        switch houseID {
        case 0: return HouseColors.color(for: .harkonnen)
        case 1: return HouseColors.color(for: .atreides)
        case 2: return HouseColors.color(for: .ordos)
        case 3: return HouseColors.color(for: .fremen)
        case 4: return HouseColors.color(for: .sardaukar)
        case 5: return HouseColors.color(for: .mercenary)
        default: return NSColor.white
        }
    }
}
