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
    /// Parallel cache of the `(groundTileID, houseIDForStructure)`
    /// currently rendered on each `tileNodes[i]`, packed as
    /// `(tileID << 8) | ownerHouseOr0`. Lets `syncGroundTiles` skip
    /// unchanged tiles cheaply + repaint when ownership or ID changes
    /// (structure placed, slab stamped, house switch).
    private var renderedGroundKeys: [UInt32] = []

    /// Cached ICN tile → `SKTexture` (base palette). Built lazily
    /// from `assets.loadIcn()`.
    private var tileTextures: [SKTexture] = []
    /// Raw ICN tile-set, kept so we can render house-remapped
    /// variants on demand (structure cells with houseID != 0).
    private var icnTileSet: Formats.Icn.TileSet?
    /// Lazy cache of house-remapped tile textures, keyed by
    /// `(tileID << 8) | houseID`. Matches the scheme used in
    /// `ScreenshotRenderer` so both code paths render byte-exact.
    private var houseRemappedTextures: [UInt32: SKTexture] = [:]

    private var frameCounter: Int = 0
    /// Debug speed multiplier. 1 = normal (1 tick per `framesPerTick`
    /// frames); N = N ticks per boundary. Bound to `,` / `.` keys.
    /// Cycle: 1 → 2 → 4 → 8 → 16 (caps; `,` halves, `.` doubles).
    private var speedMultiplier: Int = 1
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
    private var minimapNode: SKSpriteNode?

    /// Map content (tiles, unit / structure markers, explosions,
    /// halos, rally marker, placement ghost) lives under this
    /// node so we can zoom + pan the map independently of the
    /// sidebar and HUD, which stay direct children of the scene.
    /// Applied scale is `mapZoom`; applied offset is `mapPan`.
    private var mapContainer = SKNode()
    /// Map zoom factor. 4× is the default requested by the user;
    /// the old behaviour was 1× (`.aspectFit` on the whole scene).
    /// Bound to `=` / `-` keys; clamped to [1, 16].
    private var mapZoom: CGFloat = 4
    /// Current pan offset of `mapContainer`. Arrow keys shift it by
    /// `panStep` per press.
    private var mapPan: CGPoint = .zero
    private static let panStep: CGFloat = 128

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
        // Make the scene the first responder so keyDown(with:) fires.
        view.window?.makeFirstResponder(self)
        removeAllChildren()
        tileNodes.removeAll(keepingCapacity: true)
        unitMarkers.removeAll(keepingCapacity: true)
        structureMarkers.removeAll(keepingCapacity: true)
        explosionMarkers.removeAll(keepingCapacity: true)
        // Fresh map-content container for every didMove — removing
        // children on the old one is unnecessary since we drop the
        // reference wholesale.
        mapContainer = SKNode()
        mapContainer.zPosition = 0
        addChild(mapContainer)
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
            // Speed multiplier: run N sim ticks per render boundary.
            // Defaults to 1; debug keys `,` / `.` adjust.
            for _ in 0..<max(1, speedMultiplier) {
                runtime.tick()
            }
            syncVisualsFromPool()
            syncGroundTiles()
            validateSelectionHalo()
            refreshHud()
            refreshBuildSidebar()
            refreshMinimap()
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

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            runtime.deselect()
            hidePlacementGhost()
            refreshBuildSidebar()
            refreshSelectionHalo()
            refreshRallyMarker()
        case 48: // Tab
            if runtime.cycleToNextPlayerUnit() != nil {
                refreshSelectionHalo()
                refreshBuildSidebar()
            }
        case 123: // left arrow — pan camera left (content scrolls right)
            mapPan.x += Self.panStep
            applyMapTransform()
        case 124: // right arrow
            mapPan.x -= Self.panStep
            applyMapTransform()
        case 125: // down arrow
            mapPan.y += Self.panStep
            applyMapTransform()
        case 126: // up arrow
            mapPan.y -= Self.panStep
            applyMapTransform()
        case 24: // = / + — zoom in
            let before = mapZoom
            mapZoom = min(mapZoom * 2, 16)
            adjustPanForZoom(from: before, to: mapZoom)
            applyMapTransform()
        case 27: // - / _ — zoom out
            let before = mapZoom
            mapZoom = max(mapZoom / 2, 1)
            adjustPanForZoom(from: before, to: mapZoom)
            applyMapTransform()
        case 47: // . (period) — double speed
            let before = speedMultiplier
            speedMultiplier = min(speedMultiplier * 2, 16)
            if before != speedMultiplier {
                Log.info("speed \(before)× → \(speedMultiplier)×", tracer: .label("scene"))
            }
        case 43: // , (comma) — halve speed
            let before = speedMultiplier
            speedMultiplier = max(speedMultiplier / 2, 1)
            if before != speedMultiplier {
                Log.info("speed \(before)× → \(speedMultiplier)×", tracer: .label("scene"))
            }
        case 0: // A — stage attack
            handleOutcome(runtime.stageAction(.attack))
        case 46: // M — stage move
            handleOutcome(runtime.stageAction(.move))
        case 4: // H — stage harvest (harvester-only)
            handleOutcome(runtime.stageAction(.harvest))
        case 15: // R — stage return (harvester-only)
            handleOutcome(runtime.stageAction(.returnAction))
        default:
            super.keyDown(with: event)
        }
    }

    public override var acceptsFirstResponder: Bool { true }

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
        case .orderMove, .orderAttack, .orderAttackStructure:
            refreshSelectionHalo()
        case .yardSelected:
            refreshBuildSidebar()
            refreshRallyMarker()
            refreshSelectionHalo()
        case .structureSelected:
            refreshBuildSidebar()
            refreshSelectionHalo()
        case .placementStarted:
            refreshBuildSidebar()
        case .placementCommitted:
            hidePlacementGhost()
            refreshBuildSidebar()
            // Repaint the freshly-stamped tiles immediately so the
            // slab / structure appears without waiting for the next
            // 5-frame tick boundary.
            syncGroundTiles()
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
        case .orderHarvest, .orderReturn:
            refreshSelectionHalo()
            refreshHud()
        case .actionStaged, .actionStageRejected:
            refreshHud()
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
        mapContainer.addChild(marker)
        rallyMarker = marker
    }

    /// Draws a selection halo around the currently-selected entity —
    /// either a unit (green ring on the unit marker) or a structure
    /// (green rectangle outline on its footprint). Enemy selections
    /// use a red tint so it's obvious the player can't issue orders.
    /// Removes the halo when nothing is selected.
    private func refreshSelectionHalo() {
        selectionHalo?.removeFromParent()
        selectionHalo = nil

        // Unit selection takes priority.
        if let sel = commandController.selectedUnitIndex,
           let host = scheduler?.host,
           sel < host.units.slots.count,
           host.units.slots[sel].isUsed,
           let marker = unitMarkers[sel], !marker.isHidden
        {
            let halo = SKShapeNode(circleOfRadius: Self.tileSize * 0.75)
            halo.strokeColor = commandController.isFriendlySelection
                ? .green
                : NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1)
            halo.lineWidth = 2
            halo.fillColor = .clear
            halo.zPosition = 5
            marker.addChild(halo)
            selectionHalo = halo
            return
        }

        // Structure selection — draw a rectangular outline on the
        // footprint. Uses the runtime's selectedStructureIndex so
        // non-yard player buildings + enemy buildings are covered.
        if let sel = runtime.selectedStructureIndex,
           let host = scheduler?.host,
           sel < host.structures.slots.count,
           host.structures.slots[sel].isUsed
        {
            let s = host.structures.slots[sel]
            let dims = Simulation.StructureInfo.lookup(s.type)?.layout.dimensions ?? (1, 1)
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let w = CGFloat(dims.0) * Self.tileSize
            let h = CGFloat(dims.1) * Self.tileSize
            let origin = screenPosition(x: ax, y: ay + dims.1 - 1)
            let rect = CGRect(x: origin.x, y: origin.y, width: w, height: h)
            Log.info(
                "halo structure sel=\(sel) type=\(s.type) anchor=(\(ax),\(ay)) dims=\(dims.0)×\(dims.1) rect=(\(Int(rect.minX)),\(Int(rect.minY))) size=(\(Int(rect.width)),\(Int(rect.height)))",
                tracer: .label("scene-halo")
            )
            let halo = SKShapeNode(rect: rect)
            let isFriendly = s.houseID == playerHouseID
            halo.strokeColor = isFriendly
                ? .green
                : NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1)
            halo.lineWidth = 2
            halo.fillColor = .clear
            halo.zPosition = 5
            mapContainer.addChild(halo)
            selectionHalo = halo
        }
    }

    /// Applies the current `mapZoom` + `mapPan` to the mapContainer.
    /// Called after any zoom / pan change. Cheap — SpriteKit handles
    /// the transform on next draw without repositioning children.
    private func applyMapTransform() {
        mapContainer.setScale(mapZoom)
        mapContainer.position = mapPan
    }

    /// Keeps the centre of the visible map area stable across a zoom
    /// change. Given centre point `c` in scene-local coords (here
    /// `(mapSize/2, mapSize/2)` — the middle of the map area) and
    /// the content point `p` currently under that centre
    /// (`p = (c - pan_before) / zoom_before`), the new pan is
    /// `c - p * zoom_after`.
    private func adjustPanForZoom(from oldZoom: CGFloat, to newZoom: CGFloat) {
        guard oldZoom != newZoom else { return }
        let centre = CGPoint(x: Self.mapSize / 2, y: Self.mapSize / 2)
        let contentX = (centre.x - mapPan.x) / oldZoom
        let contentY = (centre.y - mapPan.y) / oldZoom
        mapPan.x = centre.x - contentX * newZoom
        mapPan.y = centre.y - contentY * newZoom
    }

    /// Centres the map container on the player's CYARD (or the
    /// first player-owned structure) so a freshly-loaded scenario
    /// presents the base at a glance. Runs right after `build()`.
    private func centerCameraOnPlayerYard() {
        guard let host = scheduler?.host else { return }
        var target: (x: Int, y: Int)? = nil
        if let yardIdx = buildController.selectedYardIndex,
           yardIdx < host.structures.slots.count,
           host.structures.slots[yardIdx].isUsed
        {
            let s = host.structures.slots[yardIdx]
            target = (Int(s.positionX) / 256, Int(s.positionY) / 256)
        }
        guard let t = target else {
            applyMapTransform()
            return
        }
        // Desired: tile t centred in the [0, mapSize) horizontal
        // window + the full vertical window.
        let centreScreenX = Self.mapSize / 2
        let centreScreenY = Self.mapSize / 2
        let contentX = (CGFloat(t.x) + 0.5) * Self.tileSize
        let contentY = (CGFloat(63 - t.y) + 0.5) * Self.tileSize
        mapPan.x = centreScreenX - contentX * mapZoom
        mapPan.y = centreScreenY - contentY * mapZoom
        applyMapTransform()
        Log.info(
            "camera centered on yard tile=(\(t.x),\(t.y)) pan=(\(Int(mapPan.x)),\(Int(mapPan.y))) zoom=\(mapZoom)",
            tracer: .label("camera")
        )
    }

    /// Pure translation from a scene-local point to a controller click.
    private func classifyClick(at p: CGPoint) -> BuildPanelController.Click {
        if p.x >= Self.mapSize {
            if let index = sidebarSlotIndex(atY: p.y) {
                return .sidebarSlot(index: index)
            }
            return .outside
        }
        // The click comes in scene-local coords. `mapContainer` is
        // scaled + panned, so we need to inverse-transform the point
        // into map-content coords before computing the tile.
        let mapX = (p.x - mapPan.x) / mapZoom
        let mapY = (p.y - mapPan.y) / mapZoom
        let tileX = Int(mapX / Self.tileSize)
        // Scene origin is bottom-left; our map indexing is top-left.
        let tileY = 63 - Int(mapY / Self.tileSize)
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
        icnTileSet = try? assets.loadIcnTileSet()

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
        // runtime.tileGrid now carries houseIDs on scenario-placed
        // structure footprints; flush them into the SKNode textures
        // before the first frame so the player sees Atreides-coloured
        // CY art on load rather than the default palette.
        syncGroundTiles()
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
        refreshMinimap()
        // Apply default 4× zoom + centre the camera on the player's
        // CYARD so fresh scenarios present the base at a glance.
        centerCameraOnPlayerYard()
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
        if speedMultiplier != 1 {
            hudText += " · \(speedMultiplier)×"
        }
        if let staged = commandController.stagedAction {
            hudText += " · STAGE \(Self.stagedActionLabel(staged)) (click target)"
        }
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

    /// Rebuilds the minimap SKSpriteNode's texture from the live
    /// tile grid + pools. Creates the node + its background frame
    /// once. Called every scheduler tick.
    private func refreshMinimap() {
        guard let host = scheduler?.host else { return }
        let tiles = runtime.tileGrid
        guard !tiles.isEmpty else { return }
        let resolver = assets.tileResolver
        let landscape: (Simulation.WorldSnapshot.Tile) -> LandscapeType = { cell in
            resolver.landscapeType(
                groundTileID: cell.groundTileID,
                overlayTileID: cell.overlayTileID,
                hasStructure: cell.hasStructure
            )
        }
        let houseColor: (UInt8) -> Minimap.ColorRGBA = { id in
            // Convert to sRGB first — `NSColor.white` is generic
            // grayscale and crashes on `.redComponent` if accessed raw.
            guard let ns = self.houseColorFor(houseID: id)
                .usingColorSpace(.sRGB)
            else {
                return Minimap.ColorRGBA(r: 0xFF, g: 0xFF, b: 0xFF)
            }
            let r = UInt8(clamping: Int((ns.redComponent * 255).rounded()))
            let g = UInt8(clamping: Int((ns.greenComponent * 255).rounded()))
            let b = UInt8(clamping: Int((ns.blueComponent * 255).rounded()))
            return Minimap.ColorRGBA(r: r, g: g, b: b)
        }
        let pixels = Minimap.render(
            tileGrid: tiles,
            landscapeAt: landscape,
            units: host.units,
            structures: host.structures,
            houseColor: houseColor
        )
        guard let cg = try? CGImageFactory.makeRGBAImage(
            bytes: pixels, width: Minimap.size, height: Minimap.size
        ) else { return }
        let texture = SKTexture(cgImage: cg)
        texture.filteringMode = .nearest

        if let node = minimapNode {
            node.texture = texture
            return
        }
        let node = SKSpriteNode(texture: texture)
        node.anchorPoint = .zero
        node.size = CGSize(width: MinimapPanel.size, height: MinimapPanel.size)
        node.position = CGPoint(
            x: Self.mapSize + (Self.sidebarWidth - MinimapPanel.size) / 2,
            y: MinimapPanel.baseY
        )
        node.zPosition = 21
        addChild(node)
        minimapNode = node
        Log.info(
            "minimap node mounted size=\(Minimap.size)×\(Minimap.size) at=(\(Int(node.position.x)),\(Int(node.position.y)))",
            tracer: .label("scene-minimap")
        )
    }

    private func addGroundTiles(world: ScenarioWorld) {
        // Initial pass uses the scene's `ScenarioWorld` (no houseID
        // on `Map.Cell`), so every node gets the default-palette
        // texture. The first `syncGroundTiles()` after `runtime.load`
        // populates `tileGrid` with per-cell houseIDs and repaints
        // structure cells through the house-remap cache. The caller
        // (`build()`) triggers that sync before `didMove` returns so
        // the player never sees a default-palette CYARD flash.
        renderedGroundKeys.reserveCapacity(64 * 64)
        for y in 0..<64 {
            for x in 0..<64 {
                let cell = world.map[x, y]
                let tileID = Int(cell.groundTileID)
                let clampedID = tileID < tileTextures.count ? tileID : 0
                let node = SKSpriteNode(texture: tileTextures[clampedID])
                node.size = CGSize(width: Self.tileSize, height: Self.tileSize)
                node.anchorPoint = .zero
                node.position = screenPosition(x: x, y: y)
                node.zPosition = 0
                mapContainer.addChild(node)
                tileNodes.append(node)
                // Record an impossible-looking key so `syncGroundTiles`
                // sees a mismatch on its first pass and repaints any
                // structure cell with its house-remapped variant.
                renderedGroundKeys.append(UInt32.max)
            }
        }
    }

    /// Packed `(tileID, owningHouseIfStructure)` cache key.
    /// Non-structure cells always use houseID=0 so ownership changes
    /// on the same tileID trigger a repaint.
    private func groundKey(tileID: Int, houseID: UInt8) -> UInt32 {
        (UInt32(tileID) << 8) | UInt32(houseID)
    }

    /// Lazy per-(tileID, houseID) texture cache. Non-structure cells
    /// (houseID == 0) use the shared `tileTextures` atlas; structure
    /// cells build a house-remapped `SKTexture` on first use via the
    /// same `pixels(forTile:houseID:)` path as `ScreenshotRenderer`.
    private func textureFor(tileID: Int, houseID: UInt8) -> SKTexture? {
        if houseID == 0 {
            guard tileID >= 0, tileID < tileTextures.count else { return nil }
            return tileTextures[tileID]
        }
        let key = groundKey(tileID: tileID, houseID: houseID)
        if let cached = houseRemappedTextures[key] { return cached }
        guard let tileSet = icnTileSet, tileID < tileSet.tileCount else {
            return (tileID < tileTextures.count) ? tileTextures[tileID] : nil
        }
        let pixels = tileSet.pixels(forTile: tileID, houseID: houseID)
        guard let cg = try? CGImageFactory.makeImage(
            indices: pixels,
            width: tileSet.tileWidth, height: tileSet.tileHeight,
            palette: assets.palette, mode: .opaque
        ) else {
            return tileTextures.indices.contains(tileID) ? tileTextures[tileID] : nil
        }
        let tx = SKTexture(cgImage: cg)
        tx.filteringMode = .nearest
        houseRemappedTextures[key] = tx
        return tx
    }

    /// Per-tick pass that re-textures any SKSpriteNode whose
    /// `groundTileID` in the live `runtime.tileGrid` no longer matches
    /// the cached value from last render. Covers runtime placements
    /// (slabs, new structures) without a full scene teardown.
    ///
    /// The runtime's `tileGrid` uses a **top-left** indexing
    /// convention (`cellIdx = y*64 + x`); `tileNodes` is flattened in
    /// that same order by `addGroundTiles`, so the linear scan stays
    /// in lock-step.
    private func syncGroundTiles() {
        let tiles = runtime.tileGrid
        guard tiles.count == tileNodes.count else { return }
        var updated = 0
        for i in 0..<tiles.count {
            let cell = tiles[i]
            let tileID = Int(cell.groundTileID)
            guard tileID < tileTextures.count else { continue }
            let houseID: UInt8 = cell.hasStructure ? cell.houseID : 0
            let key = groundKey(tileID: tileID, houseID: houseID)
            if renderedGroundKeys[i] == key { continue }
            if let tx = textureFor(tileID: tileID, houseID: houseID) {
                tileNodes[i].texture = tx
            }
            renderedGroundKeys[i] = key
            updated &+= 1
        }
        if updated > 0 {
            Log.debug(
                "ground-sync updated=\(updated) tiles",
                tracer: .label("scene")
            )
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
                let frame = UnitSpriteAtlas.resolveFrame(
                    info: info,
                    orientation: slot.orientationCurrent,
                    spriteOffset: slot.spriteOffset
                )
                let texture = unitAtlas?.texture(at: frame.spriteID, houseID: slot.houseID)
                    ?? fallbackMarkerTexture
                marker.texture = texture
                if let size = texture?.size() {
                    // Render at native sprite pixel size so relative
                    // scale between unit types survives (harvester ~24
                    // px > trike ~16 > infantry ~8). Our scene pixels
                    // and points are 1:1 with tileSize=16, which
                    // matches OpenDUNE's 16-pixel tile grid — a
                    // 24-pixel harvester spills beyond a single tile,
                    // which is the correct look. Prior "fit longest
                    // edge to tileSize" scaling collapsed everything
                    // to a uniform 16×16 and inverted the intended
                    // size hierarchy.
                    marker.size = size
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
        mapContainer.addChild(marker)
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
            // Compute the footprint rect in scene coords using the
            // exact same math as `refreshSelectionHalo` — origin is
            // the bottom-left tile of the footprint, width/height
            // scale with `dims`. Replacing the older
            // `SKShapeNode(rectOf:)` + centered-position approach
            // because it was producing a visibly offset outline on
            // live renders despite matching in headless screenshots.
            // Single-code-path removes the "two formulas must agree"
            // assumption.
            let ax = Int(slot.positionX) / 256
            let ay = Int(slot.positionY) / 256
            let origin = screenPosition(x: ax, y: ay + dims.1 - 1)
            let rect = CGRect(
                x: origin.x, y: origin.y,
                width: CGFloat(dims.0) * Self.tileSize,
                height: CGFloat(dims.1) * Self.tileSize
            )
            // Re-create the shape whenever its rect changes so the
            // node's path stays in lock-step with the computed rect.
            // Cheap — there's one marker per structure.
            structureMarkers[idx]?.removeFromParent()
            let marker = SKShapeNode(rect: rect)
            marker.fillColor = .clear
            marker.lineWidth = 1
            marker.zPosition = 1
            marker.strokeColor = houseColorFor(houseID: slot.houseID).withAlphaComponent(0.8)
            mapContainer.addChild(marker)
            structureMarkers[idx] = marker
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
                mapContainer.addChild(marker)
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
    /// and every scheduler tick so the progress bar + info panel
    /// animate.
    private func refreshBuildSidebar() {
        runtime.refreshBuildState()
        renderSidebar()
    }

    /// Layout constants for the info panel at the bottom of the
    /// right sidebar. Grows upward from the scene's y=0 line.
    private enum InfoPanel {
        static let height: CGFloat = 200
        static let headerY: CGFloat = 180      // from panel base
        static let nameY: CGFloat = 160
        static let houseY: CGFloat = 140
        static let hpLabelY: CGFloat = 120
        static let hpBarY: CGFloat = 108
        static let hpBarHeight: CGFloat = 6
        static let statusY: CGFloat = 88
        static let hintY: CGFloat = 60
    }

    /// Layout constants for the minimap panel — sits just above the
    /// info panel, square, sidebar-width minus padding on both sides.
    /// `baseY = InfoPanel.height + sidebarPadding = 204`, inlined
    /// because nested-enum default values can't reach the enclosing
    /// MainActor-isolated statics.
    private enum MinimapPanel {
        static let size: CGFloat = 120
        static let baseY: CGFloat = 204
    }

    /// Appends an info-panel block to `container` showing the current
    /// selection's name, house, HP bar, state, and action hint.
    /// Layout is fixed at the bottom of the right sidebar. Called by
    /// `renderSidebar` so the same container-teardown cycle clears old
    /// nodes.
    private func renderInfoPanel(into container: SKNode) {
        let baseX = Self.mapSize + Self.sidebarPadding
        let baseY: CGFloat = 0
        let panelWidth = Self.sidebarWidth - 2 * Self.sidebarPadding
        let panelRect = CGRect(
            x: baseX, y: baseY,
            width: panelWidth, height: InfoPanel.height
        )
        let bg = SKShapeNode(rect: panelRect)
        bg.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        bg.strokeColor = NSColor(calibratedWhite: 0.28, alpha: 1.0)
        bg.lineWidth = 1
        container.addChild(bg)

        let header = SKLabelNode(text: "INFO")
        header.fontColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        header.fontSize = 11
        header.fontName = "Menlo-Bold"
        header.horizontalAlignmentMode = .center
        header.position = CGPoint(
            x: baseX + panelWidth / 2,
            y: baseY + InfoPanel.headerY
        )
        container.addChild(header)

        // Resolve the current selection. Priority: unit > structure.
        // (Selection types are mutually exclusive in the runtime but
        // be defensive here.)
        if let unitIdx = runtime.commandController.selectedUnitIndex,
           let host = runtime.host,
           unitIdx < host.units.slots.count,
           host.units.slots[unitIdx].isUsed
        {
            renderUnitInfo(
                into: container, baseX: baseX, baseY: baseY,
                panelWidth: panelWidth,
                slot: host.units.slots[unitIdx],
                isFriendly: runtime.commandController.isFriendlySelection
            )
        } else if let structIdx = runtime.selectedStructureIndex,
                  let host = runtime.host,
                  structIdx < host.structures.slots.count,
                  host.structures.slots[structIdx].isUsed
        {
            renderStructureInfo(
                into: container, baseX: baseX, baseY: baseY,
                panelWidth: panelWidth,
                slot: host.structures.slots[structIdx]
            )
        } else {
            let hint = SKLabelNode(text: "click a unit or building")
            hint.fontColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
            hint.fontSize = 9
            hint.fontName = "Menlo"
            hint.horizontalAlignmentMode = .center
            hint.position = CGPoint(
                x: baseX + panelWidth / 2,
                y: baseY + InfoPanel.nameY
            )
            container.addChild(hint)
        }
    }

    private func renderUnitInfo(
        into container: SKNode, baseX: CGFloat, baseY: CGFloat, panelWidth: CGFloat,
        slot: Simulation.UnitSlot, isFriendly: Bool
    ) {
        let name = Self.fullUnitName(for: slot.type)
        let houseName = Self.houseName(for: slot.houseID)
        let hpMax = Simulation.UnitInfo.lookup(slot.type)?.hitpoints ?? 1
        let hpPct = max(0, min(1.0, Double(slot.hitpoints) / Double(max(1, hpMax))))

        addLabel(
            container,
            text: name, size: 13, bold: true,
            color: isFriendly ? .white : NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.65, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.nameY
        )
        addLabel(
            container,
            text: houseName,
            size: 10, bold: false,
            color: NSColor(calibratedWhite: 0.7, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.houseY
        )
        addLabel(
            container,
            text: "HP: \(slot.hitpoints)/\(hpMax)",
            size: 10, bold: false,
            color: NSColor(calibratedWhite: 0.85, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.hpLabelY
        )
        addHPBar(
            container,
            x: baseX + 6, y: baseY + InfoPanel.hpBarY,
            width: panelWidth - 12, pct: hpPct
        )

        // Action hint.
        let actionName = Self.unitActionName(for: slot.actionID)
        addLabel(
            container,
            text: "Action: \(actionName)",
            size: 9, bold: false,
            color: NSColor(calibratedWhite: 0.7, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.statusY
        )

        let hint = isFriendly
            ? "R-click: move / attack"
            : "Enemy — info only"
        addLabel(
            container,
            text: hint,
            size: 9, bold: false,
            color: isFriendly
                ? NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.4, alpha: 1)
                : NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.hintY
        )
    }

    private func renderStructureInfo(
        into container: SKNode, baseX: CGFloat, baseY: CGFloat, panelWidth: CGFloat,
        slot: Simulation.StructureSlot
    ) {
        let name = Self.fullStructureName(for: slot.type)
        let houseName = Self.houseName(for: slot.houseID)
        let isFriendly = slot.houseID == runtime.playerHouseID
        let hpMax = slot.hitpointsMax > 0
            ? slot.hitpointsMax
            : Simulation.StructureInfo.lookup(slot.type)?.hitpoints ?? 1
        let hpPct = max(0, min(1.0, Double(slot.hitpoints) / Double(max(1, hpMax))))

        addLabel(
            container,
            text: name, size: 13, bold: true,
            color: isFriendly ? .white : NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.65, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.nameY
        )
        addLabel(
            container,
            text: houseName,
            size: 10, bold: false,
            color: NSColor(calibratedWhite: 0.7, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.houseY
        )
        addLabel(
            container,
            text: "HP: \(slot.hitpoints)/\(hpMax)",
            size: 10, bold: false,
            color: NSColor(calibratedWhite: 0.85, alpha: 1),
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.hpLabelY
        )
        addHPBar(
            container,
            x: baseX + 6, y: baseY + InfoPanel.hpBarY,
            width: panelWidth - 12, pct: hpPct
        )

        if isFriendly, let state = Simulation.StructureState(rawValue: slot.state) {
            addLabel(
                container,
                text: "State: \(Self.stateName(for: state))",
                size: 9, bold: false,
                color: NSColor(calibratedWhite: 0.7, alpha: 1),
                x: baseX + panelWidth / 2, y: baseY + InfoPanel.statusY
            )
        }

        let hint: String
        let hintColor: NSColor
        if !isFriendly {
            hint = "Enemy — info only"
            hintColor = NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1)
        } else {
            let isYard = slot.type == 8 || [3, 4, 5, 7, 10].contains(slot.type)
            hint = isYard ? "sidebar: build / R-click: rally" : "owned"
            hintColor = NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.4, alpha: 1)
        }
        addLabel(
            container,
            text: hint,
            size: 9, bold: false, color: hintColor,
            x: baseX + panelWidth / 2, y: baseY + InfoPanel.hintY
        )
    }

    private func addLabel(
        _ container: SKNode, text: String, size: CGFloat, bold: Bool,
        color: NSColor, x: CGFloat, y: CGFloat
    ) {
        let label = SKLabelNode(text: text)
        label.fontColor = color
        label.fontSize = size
        label.fontName = bold ? "Menlo-Bold" : "Menlo"
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: x, y: y)
        container.addChild(label)
    }

    private func addHPBar(_ container: SKNode, x: CGFloat, y: CGFloat, width: CGFloat, pct: Double) {
        let outline = SKShapeNode(rect: CGRect(x: x, y: y, width: width, height: InfoPanel.hpBarHeight))
        outline.strokeColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        outline.fillColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        outline.lineWidth = 1
        container.addChild(outline)
        let fillWidth = width * CGFloat(pct)
        guard fillWidth > 0 else { return }
        let fill = SKShapeNode(rect: CGRect(x: x, y: y, width: fillWidth, height: InfoPanel.hpBarHeight))
        fill.strokeColor = .clear
        fill.fillColor = pct > 0.66
            ? NSColor(calibratedRed: 0.3, green: 0.9, blue: 0.4, alpha: 1)
            : pct > 0.33
                ? NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 1)
                : NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1)
        container.addChild(fill)
    }

    private static func fullUnitName(for type: UInt8) -> String {
        switch type {
        case 0: return "Carryall"
        case 1: return "Ornithopter"
        case 2: return "Infantry"
        case 3: return "Troopers"
        case 4: return "Soldier"
        case 5: return "Trooper"
        case 6: return "Saboteur"
        case 7: return "Launcher"
        case 8: return "Deviator"
        case 9: return "Tank"
        case 10: return "Siege Tank"
        case 11: return "Devastator"
        case 12: return "Sonic Tank"
        case 13: return "Trike"
        case 14: return "Raider"
        case 15: return "Quad"
        case 16: return "Harvester"
        case 17: return "MCV"
        case 25: return "Sandworm"
        case 26: return "Frigate"
        default: return "Unit \(type)"
        }
    }

    private static func fullStructureName(for type: UInt8) -> String {
        switch type {
        case 0: return "Slab (1x1)"
        case 1: return "Slab (2x2)"
        case 2: return "Palace"
        case 3: return "Light Factory"
        case 4: return "Heavy Factory"
        case 5: return "High Tech"
        case 6: return "House of IX"
        case 7: return "WOR"
        case 8: return "Construction Yard"
        case 9: return "Windtrap"
        case 10: return "Barracks"
        case 11: return "Starport"
        case 12: return "Spice Refinery"
        case 13: return "Repair"
        case 14: return "Wall"
        case 15: return "Gun Turret"
        case 16: return "Rocket Turret"
        case 17: return "Spice Silo"
        case 18: return "Outpost"
        default: return "Structure \(type)"
        }
    }

    private static func houseName(for id: UInt8) -> String {
        switch id {
        case 0: return "Harkonnen"
        case 1: return "Atreides"
        case 2: return "Ordos"
        case 3: return "Fremen"
        case 4: return "Sardaukar"
        case 5: return "Mercenary"
        default: return "House \(id)"
        }
    }

    private static func unitActionName(for id: UInt8) -> String {
        switch id {
        case 0: return "Attack"
        case 1: return "Move"
        case 2: return "Retreat"
        case 3: return "Guard"
        case 4: return "Area Guard"
        case 5: return "Harvest"
        case 6: return "Return"
        case 7: return "Stop"
        case 8: return "Ambush"
        case 9: return "Sabotage"
        case 10: return "Die"
        case 11: return "Hunt"
        case 12: return "Deploy"
        case 13: return "Destruct"
        default: return "Action \(id)"
        }
    }

    private static func stateName(for state: Simulation.StructureState) -> String {
        switch state {
        case .detect:    return "DETECT"
        case .justBuilt: return "Just Built"
        case .idle:      return "Idle"
        case .busy:      return "Busy"
        case .ready:     return "Ready"
        }
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

        // Info panel for the current selection — anchored to the
        // bottom of the sidebar.
        renderInfoPanel(into: container)
    }

    /// Top-to-bottom sidebar row placement. Row 0 lives just below the
    /// "BUILD" header; each subsequent row is `sidebarRowHeight` lower.
    private func sidebarSlotY(forIndex row: Int) -> CGFloat {
        let topMargin: CGFloat = 36
        let topY = Self.mapSize - topMargin
        return topY - CGFloat(row + 1) * Self.sidebarRowHeight
    }

    /// Inverse of `sidebarSlotY`: given a scene-local Y, returns the
    /// row index whose visible frame contains it, or nil when outside
    /// any row. Iterates row frames directly — the prior analytic
    /// formula was off by one row (click region was shifted one row
    /// below the visible highlight).
    private func sidebarSlotIndex(atY y: CGFloat) -> Int? {
        let visibleHeight = Self.sidebarRowHeight - Self.sidebarPadding
        for row in 0..<buildController.availableTypes.count {
            let slotY = sidebarSlotY(forIndex: row)
            if y >= slotY, y <= slotY + visibleHeight {
                return row
            }
        }
        return nil
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
        mapContainer.addChild(node)
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
    private static func stagedActionLabel(_ s: UnitCommandController.StagedAction) -> String {
        switch s {
        case .attack: return "ATTACK"
        case .move: return "MOVE"
        case .harvest: return "HARVEST"
        case .returnAction: return "RETURN"
        }
    }

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
