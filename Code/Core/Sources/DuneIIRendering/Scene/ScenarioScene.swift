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
    public let runtime: ScenarioRuntime
    private let scenarioName: String
    private var tileNodes: [SKSpriteNode] = []

    /// Cached ICN tile → `SKTexture`. Built lazily from `assets.loadIcn()`.
    private var tileTextures: [SKTexture] = []

    private var frameCounter: Int = 0
    private var hud: SKLabelNode?
    /// "Credits: N" readout pinned above the BUILD sidebar header.
    private var creditsLabel: SKLabelNode?
    /// Per-unit-pool-slot marker nodes, keyed by pool index.
    private var unitMarkers: [Int: SKSpriteNode] = [:]
    private var structureMarkers: [Int: SKShapeNode] = [:]
    private var explosionMarkers: [Int: SKShapeNode] = [:]
    private var unitAtlas: UnitSpriteAtlas?
    private var fallbackMarkerTexture: SKTexture?

    private var selectionHalo: SKShapeNode?
    private var rallyMarker: SKShapeNode?
    private var placementGhost: SKShapeNode?
    private var placementToast: SKLabelNode?
    private var placementToastExpiryTick: Int = -1
    private var sidebarNode: SKNode?

    // Convenience accessors — delegate to runtime.
    private var scheduler: Simulation.Scheduler? { runtime.scheduler }
    private var tickCounter: Int { runtime.tickCounter }
    private var playerHouseID: UInt8 { runtime.playerHouseID }
    private var buildController: BuildPanelController {
        get { runtime.buildController }
        set { runtime.buildController = newValue }
    }
    private var commandController: UnitCommandController {
        get { runtime.commandController }
        set { runtime.commandController = newValue }
    }
    private var currentYardKind: ScenarioRuntime.YardKind { runtime.currentYardKind }

    private var assets: AssetLoader { runtime.assets }

    public init(assets: AssetLoader, scenarioName: String) {
        self.runtime = ScenarioRuntime(assets: assets)
        self.scenarioName = scenarioName
        let size = CGSize(width: Self.mapSize + Self.sidebarWidth, height: Self.mapSize)
        super.init(size: size)
        scaleMode = .aspectFit
        backgroundColor = .black
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func didMove(to view: SKView) {
        // Enable mouse-moved events so placement ghost tracks hover.
        // Tracking area is reinstalled on each didMove since the view's
        // bounds might have changed.
        view.window?.acceptsMouseMovedEvents = true
        let tracking = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: view, userInfo: nil
        )
        view.trackingAreas.forEach(view.removeTrackingArea)
        view.addTrackingArea(tracking)
        removeAllChildren()
        tileNodes.removeAll(keepingCapacity: true)
        unitMarkers.removeAll(keepingCapacity: true)
        structureMarkers.removeAll(keepingCapacity: true)
        explosionMarkers.removeAll(keepingCapacity: true)
        frameCounter = 0
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
            runtime.tick()
            syncVisualsFromPool()
            validateSelectionHalo()
            refreshHud()
            refreshBuildSidebar()
            // Per-tick trace of the selected unit. Compact; lets the
            // developer follow a single unit across dozens of ticks
            // without the noise of every unit on the map. Skipped when
            // no unit is selected.
            if let sel = commandController.selectedUnitIndex,
               let host = scheduler?.host,
               sel < host.units.slots.count,
               host.units.slots[sel].isUsed {
                let s = host.units.slots[sel]
                let routeTail = s.route.prefix(while: { $0 != 0xFF }).map(String.init).joined(separator: ",")
                Log.debug(
                    "sel-tick \(tickCounter) u\(sel) a=\(s.actionID) pos=(\(s.positionX),\(s.positionY)) o=\(s.orientationCurrent) tgt=\(String(format: "0x%04X", s.targetMove)) curDst=(\(s.currentDestinationX),\(s.currentDestinationY)) route=[\(routeTail)]",
                    tracer: .label("sel")
                )
            }
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
        switch click {
        case .mapTile(let x, let y):
            let outcome = runtime.leftClick(tileX: x, tileY: y)
            handleOutcome(outcome)
        case .sidebarSlot(let row):
            let outcome = runtime.sidebarClick(row: row)
            handleOutcome(outcome)
        case .outside:
            break
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let type = buildController.placementType else {
            hidePlacementGhost()
            return
        }
        let location = event.location(in: self)
        let click = classifyClick(at: location)
        guard case .mapTile(let x, let y) = click else {
            hidePlacementGhost()
            return
        }
        updatePlacementGhost(type: type, tileX: x, tileY: y)
    }

    public override func rightMouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        let click = classifyClick(at: location)
        guard case .mapTile(let x, let y) = click else { return }
        let outcome = runtime.rightClick(tileX: x, tileY: y)
        handleOutcome(outcome)
    }

    /// Reacts to a runtime click outcome with the appropriate visual
    /// refresh. The runtime has already mutated sim state and logged
    /// the decision; the scene only needs to rebuild SKNodes that
    /// reflect the change.
    private func handleOutcome(_ outcome: ScenarioRuntime.ClickOutcome) {
        switch outcome {
        case .unitSelected, .unitDeselected:
            refreshSelectionHalo()
        case .orderMove, .orderAttack:
            refreshSelectionHalo()
        case .yardSelected:
            refreshBuildSidebar()
            refreshRallyMarker()
        case .placementStarted:
            refreshBuildSidebar()
        case .placementCommitted:
            hidePlacementGhost()
            refreshBuildSidebar()
        case .placementRejected:
            showPlacementToast("Can't build here — try concrete/adjacency")
            refreshBuildSidebar()
        case .placementPoolFull:
            showPlacementToast("Structure pool full")
            refreshBuildSidebar()
        case .constructionEnqueued, .constructionCancelled:
            refreshBuildSidebar()
        case .factorySpawned, .factoryPoolFull:
            refreshBuildSidebar()
        case .rallySet, .rallyCleared:
            refreshRallyMarker()
        case .none:
            break
        }
    }

    /// Per-tick guard: drop the halo + selection when the selected
    /// unit dies. Cheap no-op when nothing's selected.
    private func validateSelectionHalo() {
        guard let sel = commandController.selectedUnitIndex,
              let host = scheduler?.host else { return }
        if sel >= host.units.slots.count || !host.units.slots[sel].isUsed {
            commandController.selectedUnitIndex = nil
            selectionHalo?.removeFromParent()
            selectionHalo = nil
        }
    }

    /// Rebuilds the yellow rally-tile marker for the currently-selected
    /// factory. Removes it when no factory is selected, the selected
    /// yard isn't a factory, or the factory has no rally set.
    private func refreshRallyMarker() {
        rallyMarker?.removeFromParent()
        rallyMarker = nil
        guard let host = scheduler?.host,
              let yardIdx = buildController.selectedYardIndex,
              yardIdx < host.structures.slots.count
        else { return }
        let yard = host.structures.slots[yardIdx]
        // Factory yard types (LIGHT_VEHICLE, HEAVY_VEHICLE, HIGH_TECH, WOR, BARRACKS).
        let isFactory: Bool = [3, 4, 5, 7, 10].contains(yard.type)
        guard yard.isUsed, isFactory else { return }
        guard yard.rallyPointPacked != 0xFFFF else { return }
        let packed = Int(yard.rallyPointPacked)
        let rx = packed & 0x3F
        let ry = (packed >> 6) & 0x3F
        let half = Self.tileSize * 0.35
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: half))
        path.addLine(to: CGPoint(x: half, y: 0))
        path.addLine(to: CGPoint(x: 0, y: -half))
        path.addLine(to: CGPoint(x: -half, y: 0))
        path.closeSubpath()
        let marker = SKShapeNode(path: path)
        marker.strokeColor = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.2, alpha: 1.0)
        marker.fillColor = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.2, alpha: 0.25)
        marker.lineWidth = 2
        marker.zPosition = 4
        marker.position = CGPoint(
            x: CGFloat(rx) * Self.tileSize + Self.tileSize / 2,
            y: CGFloat(63 - ry) * Self.tileSize + Self.tileSize / 2
        )
        addChild(marker)
        rallyMarker = marker
    }

    /// Re-parents the green selection halo to whichever unit marker
    /// matches `commandController.selectedUnitIndex`. Removes the halo
    /// when nothing is selected, when the selected slot has been
    /// freed, or when the marker isn't visible yet (pre-first-tick).
    private func refreshSelectionHalo() {
        selectionHalo?.removeFromParent()
        selectionHalo = nil
        guard let sel = commandController.selectedUnitIndex else { return }
        guard let host = scheduler?.host,
              sel < host.units.slots.count,
              host.units.slots[sel].isUsed else {
            commandController.selectedUnitIndex = nil
            return
        }
        guard let marker = unitMarkers[sel], !marker.isHidden else { return }
        let halo = SKShapeNode(circleOfRadius: Self.tileSize * 0.75)
        halo.strokeColor = .green
        halo.lineWidth = 2
        halo.fillColor = .clear
        halo.zPosition = 5
        marker.addChild(halo)
        selectionHalo = halo
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
        try runtime.load(scenarioName: scenarioName)
        syncVisualsFromPool()

        let banner = SKLabelNode(text: "\(scenarioName) · click elsewhere to return")
        banner.fontColor = .white
        banner.fontSize = 14
        banner.position = CGPoint(x: Self.mapSize / 2, y: size.height - 16)
        banner.horizontalAlignmentMode = .center
        banner.zPosition = 10
        addChild(banner)

        addHud()
        refreshBuildSidebar()
        refreshRallyMarker()
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

        let credits = SKLabelNode(text: "Credits: —")
        credits.fontColor = .white
        credits.fontSize = 14
        credits.position = CGPoint(
            x: Self.mapSize + Self.sidebarWidth / 2,
            y: size.height - 16
        )
        credits.horizontalAlignmentMode = .center
        credits.zPosition = 10
        addChild(credits)
        creditsLabel = credits

        refreshHud()
    }

    private func refreshHud() {
        guard let hud else { return }
        let units = scheduler?.host.units.findArray.count ?? 0
        let structures = scheduler?.host.structures.findArray.count ?? 0
        var hudText = "Tick \(tickCounter) · units \(units) · structures \(structures)"
        if let type = buildController.placementType {
            hudText += " · PLACING \(Self.shortName(for: type)) (click map)"
        }
        hud.text = hudText

        if let creditsLabel {
            let value = scheduler.flatMap {
                Simulation.House.credits(for: playerHouseID, in: $0.host.houses)
            }
            if let value {
                creditsLabel.text = "Credits: \(value)"
            } else {
                creditsLabel.text = "Credits: —"
            }
        }

        expirePlacementToastIfDue()
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

    // MARK: - Build panel (visual only — intent lives in the runtime)

    /// Pulls freshly-computed build state from the runtime + rebuilds
    /// the sidebar nodes. Called at scene build, after every commit,
    /// and every scheduler tick so the progress bar animates.
    private func refreshBuildSidebar() {
        runtime.refreshBuildState()
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
            // Highlight priority: READY > placement-picked > idle.
            let isQueuedReady = (buildController.yardState == .ready
                                 && buildController.queuedType == type)
            let isPlacing = (buildController.placementType == type)
            if isQueuedReady {
                slotNode.strokeColor = NSColor(calibratedRed: 0.3, green: 1.0, blue: 0.35, alpha: 1)
                slotNode.lineWidth = 2
            } else if isPlacing {
                slotNode.strokeColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 1)
                slotNode.lineWidth = 2
            } else {
                slotNode.strokeColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
                slotNode.lineWidth = 1
            }
            container.addChild(slotNode)

            // Progress bar for BUSY construction.
            if buildController.yardState == .busy,
               buildController.queuedType == type,
               let progress = buildController.progress
            {
                let fillWidth = slotFrame.width * CGFloat(progress)
                let bar = SKShapeNode(rect: CGRect(
                    x: slotFrame.minX,
                    y: slotFrame.minY,
                    width: fillWidth,
                    height: 3
                ))
                bar.fillColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 0.9)
                bar.strokeColor = .clear
                container.addChild(bar)
            }

            // Icon — branches by yard kind.
            //   .structure → last tile of the structure's iconGroup
            //   .unit      → unit atlas texture at the unit's
            //               groundSpriteID (idle/north-facing frame)
            switch currentYardKind {
            case .structure:
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
            case .unit:
                if let info = Simulation.UnitInfo.lookup(type),
                   let texture = unitAtlas?.texture(
                       at: Int(info.groundSpriteID), houseID: playerHouseID
                   )
                {
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
            let label = SKLabelNode(text: currentYardKind == .structure
                                    ? Self.shortName(for: type)
                                    : Self.shortUnitName(for: type))
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

    /// Rebuilds the placement ghost at `(tileX, tileY)` for `type`. The
    /// ghost is a coloured rectangle covering the structure's footprint:
    /// green when valid, yellow when degraded, red when invalid. Called
    /// from `mouseMoved` while `placementType != nil`.
    private func updatePlacementGhost(type: UInt8, tileX: Int, tileY: Int) {
        placementGhost?.removeFromParent()
        let dims = Simulation.StructureInfo.lookup(type)?.layout.dimensions ?? (1, 1)
        let w = CGFloat(dims.0) * Self.tileSize
        let h = CGFloat(dims.1) * Self.tileSize
        let origin = screenPosition(x: tileX, y: tileY + dims.1 - 1)
        let frame = CGRect(x: origin.x, y: origin.y, width: w, height: h)
        let node = SKShapeNode(rect: frame)
        let validity = runtime.placementValidity(type: type, tileX: tileX, tileY: tileY) ?? 0
        let color: NSColor
        switch validity {
        case let v where v > 0:  color = NSColor(calibratedRed: 0.2, green: 1.0, blue: 0.3, alpha: 1)
        case let v where v < 0:  color = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.2, alpha: 1)
        default:                  color = NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.25, alpha: 1)
        }
        node.strokeColor = color
        node.fillColor = color.withAlphaComponent(0.2)
        node.lineWidth = 2
        node.zPosition = 8
        addChild(node)
        placementGhost = node
    }

    private func hidePlacementGhost() {
        placementGhost?.removeFromParent()
        placementGhost = nil
    }

    /// Shows a transient toast near the top of the map. Auto-cleared
    /// ~24 ticks (~2 seconds at 12 Hz) later via `refreshHud`.
    private func showPlacementToast(_ text: String) {
        placementToast?.removeFromParent()
        let label = SKLabelNode(text: text)
        label.fontColor = NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.25, alpha: 1)
        label.fontSize = 14
        label.fontName = "Menlo-Bold"
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: Self.mapSize / 2, y: Self.mapSize - 40)
        label.zPosition = 30
        addChild(label)
        placementToast = label
        placementToastExpiryTick = tickCounter + 24
    }

    private func expirePlacementToastIfDue() {
        guard let toast = placementToast else { return }
        if tickCounter >= placementToastExpiryTick {
            toast.removeFromParent()
            placementToast = nil
        }
    }

    /// Short name for unit-type sidebar labels. Mirrors in-game
    /// abbreviations without pulling in the string-table assets.
    private static func shortUnitName(for type: UInt8) -> String {
        switch type {
        case 0:  return "Carry"
        case 1:  return "Thopt"
        case 2:  return "Infant"
        case 3:  return "Troops"
        case 4:  return "Soldr"
        case 5:  return "Trper"
        case 6:  return "Sabot"
        case 7:  return "Launch"
        case 8:  return "Devi."
        case 9:  return "Tank"
        case 10: return "Siege"
        case 11: return "Devst"
        case 12: return "Sonic"
        case 13: return "Trike"
        case 14: return "Raider"
        case 15: return "Quad"
        case 16: return "Harv"
        case 17: return "MCV"
        case 18: return "D.Hand"
        case 25: return "Worm"
        case 26: return "Frigt"
        default: return "?"
        }
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
