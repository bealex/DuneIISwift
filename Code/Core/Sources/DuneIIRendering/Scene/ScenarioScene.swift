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

    public init(assets: AssetLoader, scenarioName: String) {
        self.assets = assets
        self.scenarioName = scenarioName
        let size = CGSize(width: Self.tileSize * 64, height: Self.tileSize * 64)
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
        coordinator?.route(to: .mainMenu)
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

        let banner = SKLabelNode(text: "\(scenarioName) · click to return")
        banner.fontColor = .white
        banner.fontSize = 14
        banner.position = CGPoint(x: size.width / 2, y: size.height - 16)
        banner.horizontalAlignmentMode = .center
        banner.zPosition = 10
        addChild(banner)

        addHud()
    }

    /// Builds a live `Simulation.WorldSnapshot` from the scenario spawns,
    /// wraps the pools in a `Scripting.Host`, and wires a `Scheduler` with
    /// the install's `UNIT.EMC` / `BUILD.EMC` programs (empty function
    /// tables — scripts halt on first `FUNCTION` opcode; that's expected).
    private func setUpScheduler(scenario: Scenario, resolver: TileResolver) throws {
        let snapshot = try Simulation.WorldSnapshot(scenario: scenario, resolver: resolver)
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
