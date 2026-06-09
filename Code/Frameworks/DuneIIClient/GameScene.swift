import DuneIIContracts
import DuneIIFormats
import DuneIIInput
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import SpriteKit

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

/// The map view: renders the live `Simulation` through `SpriteKitRenderer`, drives the camera from the
/// model's `Viewport` (scroll/zoom, pixel-perfect), forwards input to the model (select/order, +/- zoom,
/// scroll), and overlays the selection outline + (debug) per-unit health bars. Rendering is cross-platform
/// (`SKColor`); the raw input handlers are conditionally compiled per platform (`#if os`), both converting
/// to a tile/world point via the shared `tile(atScenePoint:)` / `tile(fromView:)` helpers below.
@MainActor
public final class GameScene: SKScene {
    static let worldSidePx = Int(Viewport.worldSize)  // 1024
    private static let tileSize = 16
    private static let barWidth = 7.0  // half the old 14 (user: "width 2x smaller")
    private static let barHeight = 1.0  // half the old 2 (user: "height 2x smaller")

    /// Temporary / projectile unit types that never get a health bar (bullets, rockets, sonic blasts).
    private static let projectileTypes: Set<UnitType> = [
        .missileHouse, .missileRocket, .missileTurret, .missileDeviator, .missileTrooper, .bullet, .sonicBlast,
    ]

    /// The base sim cadence: at `gameSpeed == 1` the scene advances ~60 sim ticks per real second (one per
    /// drawn frame at 60 fps). The speed multiplier scales this against wall-clock time.
    private static let baseTicksPerSecond = 60.0

    private weak var model: GameModel?
    private let cam = SKCameraNode()
    private var renderer: SpriteKitRenderer?
    private var lastUpdateTime: TimeInterval = 0
    private var tickAccumulator = 0.0
    private let borderLayer = SKNode()  // the decorative Dune border ring filling the scrollable map margin
    private var lastBorderArea: CGRect?  // the playable area the border was last built for (rebuild on change)
    private let selectionLayer = SKNode()  // outline(s) around the selected unit(s)/structure
    private var selectionNodes: [SKShapeNode] = []  // pulsating square outline(s) for a selected building
    private var unitSelectNodes: [SKSpriteNode] = []  // the MOUSE.SHP[6] selection box around each selected unit
    private lazy var unitSelectTexture: SKTexture? = makeUnitSelectTexture()  // MOUSE/006, built once
    private lazy var leaderFlagNode: SKShapeNode = makeLeaderFlag()  // a small pennant over the group's leader
    private let dragBoxNode = SKShapeNode()  // the drag-select rubber-band box
    // Left-drag (drag-select) gesture state.
    private var leftDragStartWindow: CGPoint?
    private var leftDragStartTile: (Int, Int)?
    private var leftDragging = false
    private let placementNode = SKShapeNode()  // structure-placement footprint preview
    #if os(macOS)
        private var trackingArea: NSTrackingArea?
    #endif
    // Middle-button pan/recentre state: the last cursor point (window coords, camera-independent), whether
    // this gesture moved, and the down point (scene coords) for a click-recentre.
    private var middleDragLastWindow: CGPoint?
    private var middleDidDrag = false
    private var middleDownScene: CGPoint?
    #if os(iOS)
        // Touch state: a single finger taps (select / place / armed-order) or drags to pan; two fingers pinch to
        // zoom; a stationary long-press issues the default order (the macOS right-click). Scene coords are y-up.
        private var touchStartScene: CGPoint?
        private var touchLastScene: CGPoint?
        private var touchLastView: CGPoint?  // last finger point in view coords, for a 1:1 (finger-following) pan
        private var touchDidPan = false
        private var pinchStartDistance: CGFloat?
        private var pinchStartZoom: Double?  // the magnification when the two-finger pinch began
        private var longPressWork: DispatchWorkItem?
        private var longPressFired = false
        // Touches that start within this many points of a view edge are ignored — they're usually system
        // edge-swipes (Control Center / app switcher / back) or an accidental palm/grip, not gameplay.
        private static let edgeMargin = 15.0
        // Multi-tap: repeated taps on the same tile within this window escalate the selection — one tap
        // single-selects, two select the same-type cluster, three select every same-type unit on the map.
        private var lastTapTime: TimeInterval = 0
        private var lastTapTile: (Int, Int)?
        private var tapCount = 0
        private static let doubleTapWindow = 0.35
    #endif
    #if os(macOS)
        // Map-cursor state. Cache the cursor's current *meaning* so we only call `NSCursor.set()` on a change,
        // and remember the last tile the pointer was over so the per-frame refresh can re-derive the cursor
        // after a selection / world change (not only on mouse-move). `duneCursorCache` holds the authentic
        // `MOUSE.SHP` cursors, built once.
        private enum MapCursor: Equatable { case arrow, crosshair, move, attack }
        private var currentMapCursor: MapCursor = .arrow
        private var lastMouseTile: (x: Int, y: Int)?
        private var duneCursorCache: [Int: NSCursor] = [:]
    #endif
    private let healthLayer = SKNode()
    private var healthBars: [SKSpriteNode] = []
    private var buildBars: [SKSpriteNode] = []  // a white production-progress bar under a building's health bar
    private var stateChips: [SKShapeNode] = []  // a small shape+colour action chip per unit health bar

    init(model: GameModel) {
        self.model = model
        super.init(size: CGSize(width: Self.worldSidePx, height: Self.worldSidePx))
        scaleMode = .resizeFill
        backgroundColor = .black
        addChild(cam)
        camera = cam
        borderLayer.zPosition = 0.5  // above the (black) terrain border cells, below overlays/sprites
        addChild(borderLayer)
        selectionLayer.zPosition = 30
        addChild(selectionLayer)
        leaderFlagNode.isHidden = true
        selectionLayer.addChild(leaderFlagNode)
        dragBoxNode.strokeColor = .green
        dragBoxNode.lineWidth = 1
        dragBoxNode.fillColor = SKColor.green.withAlphaComponent(0.12)
        dragBoxNode.zPosition = 40
        dragBoxNode.isHidden = true
        addChild(dragBoxNode)
        placementNode.lineWidth = 1.5
        placementNode.zPosition = 35
        placementNode.isHidden = true
        addChild(placementNode)
        healthLayer.zPosition = 40
        addChild(healthLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Track mouse-moved events so the placement preview can follow the cursor (the click-to-place path
    /// works without this; the preview just won't follow until the next click).
    override public func didMove(to view: SKView) {
        #if os(iOS)
            // Without this the view tracks only the first finger, so a second finger landing *after* the first
            // (e.g. when you deliberately place one finger on a unit, then pinch) is dropped — and pinch fails.
            view.isMultipleTouchEnabled = true
        #endif
        #if os(macOS)
            view.window?.acceptsMouseMovedEvents = true
            if trackingArea == nil {
                // `.activeAlways` (not `.activeInKeyWindow`): hover/cursor updates over the map keep working while
                // a floating tool window holds focus, matching the first-mouse click handling (`FirstMouseSKView`).
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [ .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect ],
                    owner: self
                )
                view.addTrackingArea(area)
                trackingArea = area
            }
        #endif
    }

    func load(simulation: Simulation, assets: AssetStore) {
        // Keep our overlay nodes — only drop the renderer's terrain/sprite nodes. (The placement-preview node
        // was being orphaned here, so its footprint never drew.)
        let keep: [SKNode] = [ cam, borderLayer, selectionLayer, dragBoxNode, healthLayer, placementNode ]
        for child in children where !keep.contains(child) { child.removeFromParent() }
        let r = SpriteKitRenderer(
            source: SpriteSource.make(assets: assets),
            basePalette: assets.palette,
            showFog: model?.showFog ?? false
        )
        // Rebuild the sandworm heat-haze every other frame, not every frame: the worm patch's per-frame
        // SKTexture upload was the biggest per-frame texture cost, and halving it is imperceptible.
        r.shimmerUpdateInterval = 2
        r.attach(to: self)
        r.render(simulation.makeFrameInfo())
        renderer = r
    }

    func applyFog() {
        guard let renderer, let frame = model?.lastFrame else { return }

        renderer.showFog = model?.showFog ?? false
        renderer.rebuildTerrain(frame)
    }

    override public func update(_ currentTime: TimeInterval) {
        guard let model, let renderer else { return }

        // Pace sim ticks against real elapsed time × the speed multiplier, so 0.5× runs half as fast and
        // 4× four times. The accumulator carries fractional ticks across frames; the per-frame step count
        // is capped so a hitch (or a tab-out) can't trigger a long catch-up spiral.
        let dt = lastUpdateTime == 0 ? 0 : min(0.25, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        tickAccumulator += dt * Self.baseTicksPerSecond * model.gameSpeed
        var steps = Int(tickAccumulator)
        if steps > 0 { tickAccumulator -= Double(steps) }
        steps = min(steps, 16)
        guard let frame = model.advance(ticks: steps) else { return }

        model.viewSize = size  // keep the model's view size current for clamping
        renderer.render(frame)
        model.advanceRadarTuning()  // wall-clock paced (per render frame), independent of game speed
        updateBorder()
        applyViewport()
        updateSelection()
        updateHealth(frame, show: model.showHealthOverlay)
        updatePlacement()
        refreshCursor()
    }

    // MARK: - Placement preview

    /// Draw the structure-placement footprint at the hovered tile — green where valid, red where blocked.
    private func updatePlacement() {
        guard
            let model,
            let p = model.placement,
            let tx = p.hoverTileX,
            let ty = p.hoverTileY
        else {
            placementNode.isHidden = true; return
        }

        let valid = model.placementValidity(tileX: tx, tileY: ty) != 0
        let tile = Self.tileSize
        let originX = Double(tx * tile)
        let bottomY = Double(Self.worldSidePx - (ty + p.height) * tile)
        let rect = CGRect(x: originX, y: bottomY, width: Double(p.width * tile), height: Double(p.height * tile))
        placementNode.path = CGPath(rect: rect, transform: nil)
        let colour: SKColor = valid ? .systemGreen : .systemRed
        placementNode.strokeColor = colour
        placementNode.fillColor = colour.withAlphaComponent(0.25)
        placementNode.isHidden = false
    }

    /// Camera = the model's viewport: scale `1/zoom`, centred on the world point (image y-down → scene y-up).
    private func applyViewport() {
        guard let v = model?.viewport else { return }

        cam.setScale(1 / v.zoom)
        cam.position = CGPoint(x: v.centerX, y: Double(Self.worldSidePx) - v.centerY)
    }

    // MARK: - Map border frame

    /// Test seam (`ClientTests`): the border frame's nodes.
    var debugBorderStrips: [SKSpriteNode] { borderLayer.children.compactMap { $0 as? SKSpriteNode } }

    /// Build the map border ring around the playable area (once per area change), filling the `Viewport.borderPx`
    /// margin the camera can scroll into with the **concrete-slab tile** (16×16) tiled. Top + bottom span the
    /// corners; left + right fill the height between. Sits above the (black) terrain border cells, below units.
    private func updateBorder() {
        guard let area = model?.viewport.area, area != lastBorderArea else { return }

        lastBorderArea = area
        borderLayer.removeAllChildren()
        guard let tile = model?.assets.concreteTile() else { return }

        let b = Viewport.borderPx  // 16 = one tile
        let side = Double(Self.worldSidePx)
        let ax0 = area.minX, aw = area.width, ah = area.height
        let topY = side - area.minY  // scene-y (y-up) of the area's top edge
        let botY = side - area.maxY
        let midY = (topY + botY) / 2

        func strip(centerX: Double, centerY: Double, width: Double, height: Double) {
            guard
                let texture = tiledTileTexture(
                    tile.indices,
                    palette: tile.palette,
                    width: Int(width),
                    height: Int(height)
                )
            else { return }

            let node = SKSpriteNode(texture: texture)
            node.size = CGSize(width: width, height: height)
            node.position = CGPoint(x: centerX, y: centerY)
            borderLayer.addChild(node)
        }
        strip(centerX: ax0 + aw / 2, centerY: topY + b / 2, width: aw + 2 * b, height: b)
        strip(centerX: ax0 + aw / 2, centerY: botY - b / 2, width: aw + 2 * b, height: b)
        strip(centerX: ax0 - b / 2, centerY: midY, width: b, height: ah)
        strip(centerX: ax0 + aw + b / 2, centerY: midY, width: b, height: ah)
    }

    /// Tile a 16×16 indexed terrain tile across a `width × height` strip → a nearest-filtered texture.
    private func tiledTileTexture(_ tile: [UInt8], palette: Palette, width: Int, height: Int) -> SKTexture? {
        guard width > 0, height > 0, tile.count >= 256 else { return nil }

        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width { indices[y * width + x] = tile[(y % 16) * 16 + (x % 16)] }
        }
        guard let image = IndexedImage.cgImage(indices: indices, width: width, height: height, palette: palette) else {
            return nil
        }

        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    // MARK: - Selection outline

    private func updateSelection() {
        let boxes = model?.selectionBoxes() ?? []
        var usedSquares = 0, usedSprites = 0
        leaderFlagNode.isHidden = true
        for box in boxes {
            if box.isLeader {
                // Plant the leader's flag at the top-centre of its tile (pole rises from there). One leader
                // per group, so a single shared node suffices.
                leaderFlagNode.position = CGPoint(
                    x: box.centerX,
                    y: Double(Self.worldSidePx) - box.centerY + box.height / 2
                )
                leaderFlagNode.isHidden = false
            }
            if box.isStructure {
                // A building: a white square outline that pulsates (alpha 0↔1, 3 s period).
                let node = pooledSelectionSquare(usedSquares); usedSquares += 1
                let originX = box.centerX - box.width / 2
                let bottomY = Double(Self.worldSidePx) - (box.centerY + box.height / 2)  // image y-down → scene y-up
                node.path = CGPath(
                    rect: CGRect(x: originX, y: bottomY, width: box.width, height: box.height),
                    transform: nil
                )
                node.isHidden = false
            } else if let texture = unitSelectTexture {
                // A unit: the original selection-box sprite (`MOUSE.SHP` frame 6 = `g_sprites[6]`), centred.
                let node = pooledUnitSelect(usedSprites); usedSprites += 1
                node.texture = texture
                node.size = texture.size()
                node.position = CGPoint(x: box.centerX, y: Double(Self.worldSidePx) - box.centerY)
                node.isHidden = false
            }
        }
        for i in usedSquares ..< selectionNodes.count { selectionNodes[i].isHidden = true }
        for i in usedSprites ..< unitSelectNodes.count { unitSelectNodes[i].isHidden = true }
    }

    /// A pulsating white square-outline node for a selected building (alpha cycles 1→0→1 over 3 s).
    private func pooledSelectionSquare(_ i: Int) -> SKShapeNode {
        while i >= selectionNodes.count {
            let n = SKShapeNode()
            n.strokeColor = .white; n.lineWidth = 1.5; n.fillColor = .clear
            n.run(
                .repeatForever(.sequence([ .fadeAlpha(to: 0, duration: 1.5), .fadeAlpha(to: 1, duration: 1.5) ])),
                withKey: "pulse"
            )
            selectionNodes.append(n); selectionLayer.addChild(n)
        }
        return selectionNodes[i]
    }

    /// A small pennant marking the selection's leader: a thin white pole rising from the unit's top with a
    /// filled triangular flag near the tip. Built in world pixels (it scales with the camera, anchored at the
    /// pole base so `position` plants it on the unit). `zPosition` above the selection boxes.
    private func makeLeaderFlag() -> SKShapeNode {
        let pole = CGMutablePath()
        pole.move(to: CGPoint(x: 0, y: 0))
        pole.addLine(to: CGPoint(x: 0, y: 13))
        let pennant = CGMutablePath()  // a right-pointing triangle near the pole tip
        pennant.move(to: CGPoint(x: 0, y: 13))
        pennant.addLine(to: CGPoint(x: 8, y: 10.5))
        pennant.addLine(to: CGPoint(x: 0, y: 8))
        pennant.closeSubpath()

        let node = SKShapeNode()
        let combined = CGMutablePath()
        combined.addPath(pole)
        combined.addPath(pennant)
        node.path = combined
        node.strokeColor = .white
        node.lineWidth = 1
        node.fillColor = SKColor(red: 1, green: 0.82, blue: 0.1, alpha: 1)  // a Dune-yellow pennant
        node.isAntialiased = false
        node.zPosition = 1  // above the sibling selection-box sprites in `selectionLayer`
        return node
    }

    private func pooledUnitSelect(_ i: Int) -> SKSpriteNode {
        while i >= unitSelectNodes.count {
            let n = SKSpriteNode()
            n.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            unitSelectNodes.append(n); selectionLayer.addChild(n)
        }
        return unitSelectNodes[i]
    }

    /// Decode `MOUSE.SHP` frame 6 (the original unit selection box, `g_sprites[6]`) into a nearest-filtered
    /// texture through the asset palette (index 0 transparent). `nil` if the asset is missing.
    private func makeUnitSelectTexture() -> SKTexture? {
        guard let assets = model?.assets, let shp = assets.shp("MOUSE.SHP"), shp.frames.count > 6 else { return nil }

        let f = shp.frames[6]
        guard
            let cg = IndexedImage.cgImage(
                indices: f.pixels,
                width: f.width,
                height: f.height,
                palette: assets.palette,
                transparentIndex: 0
            )
        else { return nil }

        let texture = SKTexture(cgImage: cg)
        texture.filteringMode = .nearest
        return texture
    }

    /// Draw the drag-select rubber-band over the tile rectangle from `from` to `to` (inclusive).
    private func setDragBox(from: (Int, Int), to: (Int, Int)) {
        let minX = min(from.0, to.0), maxX = max(from.0, to.0)
        let minY = min(from.1, to.1), maxY = max(from.1, to.1)
        let x = Double(minX * Self.tileSize)
        let w = Double((maxX - minX + 1) * Self.tileSize)
        let bottomY = Double(Self.worldSidePx - (maxY + 1) * Self.tileSize)
        let h = Double((maxY - minY + 1) * Self.tileSize)
        dragBoxNode.path = CGPath(rect: CGRect(x: x, y: bottomY, width: w, height: h), transform: nil)
        dragBoxNode.isHidden = false
    }

    // MARK: - Health/state overlay

    /// Health bars (+ unit state chips) over real units and buildings — never over bullets/rockets/effects,
    /// and never over entities hidden in the fog (they aren't drawn, so neither is their bar).
    private func updateHealth(_ frame: FrameInfo, show: Bool) {
        guard show else { hideAllHealth(); return }

        let fog = model?.showFog ?? false
        let side = Double(Self.worldSidePx)
        let tile = Double(Self.tileSize)
        var usedBars = 0, usedChips = 0, usedBuildBars = 0

        // Real units (projectiles skipped). Smooth sub-tile position; bar a little above the sprite centre.
        for unit in frame.units where !Self.projectileTypes.contains(unit.type) {
            if FrameComposer.isHiddenByFog(frame, worldX: unit.positionX, worldY: unit.positionY, showFog: fog) {
                continue
            }
            let frac = unit.hitpointsMax > 0 ? Double(unit.hitpoints) / Double(unit.hitpointsMax) : 1
            let cx = Double(unit.positionX) * tile / 256
            let cy = Double(unit.positionY) * tile / 256
            let barLeft = cx - Self.barWidth / 2
            // Just above the sprite (closer than before): the sprite half-height is ~8 px, so a 7 px offset
            // sits right at its top edge.
            let barY = side - (cy - 7)
            placeBar(usedBars, left: barLeft, y: barY, width: Self.barWidth, frac: frac); usedBars += 1

            // A state chip (distinct shape + colour) just left of the bar; idle shows none.
            if let (path, colour) = Self.chipStyle(unit.activity) {
                let chip = pooledChip(usedChips); usedChips += 1
                chip.path = path; chip.fillColor = colour; chip.strokeColor = colour
                chip.position = CGPoint(x: barLeft - 2.5, y: barY)
                chip.isHidden = false
            }
        }

        // Buildings: a footprint-width bar drawn over the building's top row of pixels (hidden in fog).
        for s in frame.structures {
            if FrameComposer.isHiddenByFog(frame, worldX: s.positionX, worldY: s.positionY, showFog: fog) { continue }
            let frac = s.hitpointsMax > 0 ? Double(s.hitpoints) / Double(s.hitpointsMax) : 1
            let (w, h) = Self.structureFootprint(s.type)
            let widthPx = Double(w) * tile
            let cornerX = Double(s.positionX) * tile / 256
            let cornerY = Double(s.positionY) * tile / 256
            let barW = max(8, widthPx - 4)
            let barLeft = cornerX + (widthPx - barW) / 2
            // `cornerY` is the building's top edge (image space); +1 puts the bar on its first row of pixels.
            let healthY = side - (cornerY + 1)
            placeBar(usedBars, left: barLeft, y: healthY, width: barW, frac: frac)
            usedBars += 1

            // The production-progress bar (blue) sits at the **bottom** edge of the building footprint while the
            // factory/CY is building or repairing — the health bar is at the top. Its lower edge sits just inside
            // the building's bottom row.
            if let progress = s.buildProgress {
                let buildY = side - (cornerY + Double(h) * tile) + Self.barHeight / 2
                placeBuildBar(usedBuildBars, left: barLeft, y: buildY, width: barW, frac: progress)
                usedBuildBars += 1
            }
        }

        for i in usedBars ..< healthBars.count { healthBars[i].isHidden = true }
        for i in usedBuildBars ..< buildBars.count { buildBars[i].isHidden = true }
        for i in usedChips ..< stateChips.count { stateChips[i].isHidden = true }
    }

    /// A blue build-progress bar (`buildBars` pool), same geometry + rules as `placeBar` but a fixed blue
    /// colour: full width at 100% readiness, zero width at 0% — left-anchored, so it fills left→right.
    private func placeBuildBar(_ i: Int, left: Double, y: Double, width: Double, frac: Double) {
        while i >= buildBars.count {
            let bar = SKSpriteNode(color: .systemBlue, size: CGSize(width: Self.barWidth, height: Self.barHeight))
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            buildBars.append(bar); healthLayer.addChild(bar)
        }
        let bar = buildBars[i]
        let clamped = min(1, max(0, frac))
        bar.size = CGSize(width: width * clamped, height: Self.barHeight)
        bar.position = CGPoint(x: left, y: y)
        bar.color = .systemBlue
        bar.isHidden = false
    }

    private func placeBar(_ i: Int, left: Double, y: Double, width: Double, frac: Double) {
        let bar = pooledBar(i)
        // The bar's drawn width *is* the health fraction of the full width: full → 100% length, half → 50%,
        // dead → 0. Left-anchored (anchorPoint x=0), so it depletes from the right. Colour is the additional
        // cue. (Width set directly rather than via `xScale`, so the depletion is unambiguous.)
        let clamped = min(1, max(0, frac))
        bar.size = CGSize(width: width * clamped, height: Self.barHeight)
        bar.position = CGPoint(x: left, y: y)
        bar.color = frac > 0.66 ? .green : (frac > 0.33 ? .yellow : .red)
        bar.isHidden = frac <= 0
    }

    private func hideAllHealth() {
        for bar in healthBars { bar.isHidden = true }
        for bar in buildBars { bar.isHidden = true }
        for chip in stateChips { chip.isHidden = true }
    }

    /// idle → no chip; otherwise a distinct **shape + colour** per state (centred on the node origin):
    /// move = green ▶ triangle, attack = red ◆ diamond, guard = blue ■ square, harvest = orange ● circle.
    private static func chipStyle(_ activity: FrameInfo.UnitActivity) -> (CGPath, SKColor)? {
        let r = 1.25  // half the old 2.5 — the state icons are 2× smaller
        switch activity {
            case .idle: return nil
            case .moving:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -r, y: -r)); p.addLine(to: CGPoint(x: r, y: 0));
                p.addLine(to: CGPoint(x: -r, y: r)); p.closeSubpath()
                return (p, .systemGreen)
            case .attacking:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: r, y: 0))
                p.addLine(to: CGPoint(x: 0, y: -r)); p.addLine(to: CGPoint(x: -r, y: 0)); p.closeSubpath()
                return (p, .systemRed)
            case .guarding:
                return (CGPath(rect: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil), .systemBlue)
            case .harvesting:
                return (
                    CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil), .systemOrange
                )
        }
    }

    private static func structureFootprint(_ type: StructureType) -> (Int, Int) {
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        return (Int(layout.size.width), Int(layout.size.height))
    }

    private func pooledBar(_ i: Int) -> SKSpriteNode {
        while i >= healthBars.count {
            let bar = SKSpriteNode(color: .green, size: CGSize(width: Self.barWidth, height: Self.barHeight))
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            healthBars.append(bar); healthLayer.addChild(bar)
        }
        return healthBars[i]
    }

    private func pooledChip(_ i: Int) -> SKShapeNode {
        while i >= stateChips.count {
            let chip = SKShapeNode()
            chip.lineWidth = 0
            stateChips.append(chip); healthLayer.addChild(chip)
        }
        return stateChips[i]
    }

    // MARK: - Input

    /// Convert a point in scene coordinates (already camera-adjusted) to a `(tileX, tileY)`, or nil if it
    /// falls outside the 64×64 map. Every platform's input layer funnels through this.
    public func tile(atScenePoint p: CGPoint) -> (Int, Int)? {
        // Reject points outside the playable square *before* dividing: integer division truncates toward zero,
        // so a small negative coord (a click in the scrollable border margin, p.x ∈ [-borderPx, 0)) would
        // otherwise collapse to tile 0 and slip past the `0 ..< 64` guard.
        guard p.x >= 0, p.y >= 0, p.x < CGFloat(Self.worldSidePx), p.y < CGFloat(Self.worldSidePx) else {
            return nil
        }

        let x = Int(p.x) / Self.tileSize
        let y = (Self.worldSidePx - Int(p.y)) / Self.tileSize
        guard (0 ..< 64).contains(x), (0 ..< 64).contains(y) else { return nil }

        return (x, y)
    }

    /// Convert a point in the presenting `SKView`'s coordinate space to a map tile (iOS gestures use this).
    public func tile(fromView viewPoint: CGPoint) -> (Int, Int)? {
        guard view != nil else { return nil }

        return tile(atScenePoint: convertPoint(fromView: viewPoint))
    }

    /// Convert a view point to a world point (image space, y-down) — e.g. to recentre the camera on a tap.
    public func worldPoint(fromView viewPoint: CGPoint) -> CGPoint? {
        guard view != nil else { return nil }

        let p = convertPoint(fromView: viewPoint)
        return CGPoint(x: p.x, y: Double(Self.worldSidePx) - p.y)
    }

    /// True while the next primary tap supplies a target: an armed unit order, structure placement, or the
    /// palace death-hand target-select.
    private var targetingActive: Bool {
        (model?.pendingOrder != nil) || (model?.placement != nil) || (model?.missileTargeting != nil)
    }

    /// Re-derive the map cursor from the current targeting / selection / hovered-tile state, applied only when
    /// its meaning changed (so a selection or world change updates it even without a mouse-move). macOS only:
    /// iOS has no hardware cursor, so this is a no-op there.
    private func refreshCursor() {
        #if os(macOS)
            applyMapCursor()
        #endif
    }

    #if os(macOS)
        private func tile(at event: NSEvent) -> (Int, Int)? { tile(atScenePoint: event.location(in: self)) }

        // Left-click is resolved on mouse-UP so a press-drag-release can be a drag-select box instead. The
        // special modes (missile target-select, structure placement, an armed order) act on a plain click and
        // suppress drag-select.
        override public func mouseDown(with event: NSEvent) {
            leftDragStartWindow = event.locationInWindow
            leftDragStartTile = tile(at: event)
            leftDragging = false
        }

        override public func mouseDragged(with event: NSEvent) {
            guard
                let start = leftDragStartWindow,
                model?.missileTargeting == nil,
                model?.placement == nil,
                model?.pendingOrder == nil
            else { return }

            let cur = event.locationInWindow
            if hypot(cur.x - start.x, cur.y - start.y) > 4 { leftDragging = true }
            if leftDragging, let from = leftDragStartTile, let to = tile(at: event) { setDragBox(from: from, to: to) }
        }

        override public func mouseUp(with event: NSEvent) {
            defer {
                leftDragStartWindow = nil; leftDragStartTile = nil; leftDragging = false; dragBoxNode.isHidden = true
            }
            if leftDragging, let from = leftDragStartTile, let to = tile(at: event) {
                model?.dragSelect(fromTileX: from.0, fromTileY: from.1, toTileX: to.0, toTileY: to.1)
                return
            }
            guard let (x, y) = tile(at: event) else { return }

            if model?.missileTargeting != nil {
                model?.launchMissileAt(tileX: x, tileY: y)
            } else if model?.placement != nil {
                model?.placeAt(tileX: x, tileY: y)
            } else if event.clickCount >= 3 {
                // Triple-click a unit → select every same-type unit on the map.
                model?.tripleClickSelectAllSameType(tileX: x, tileY: y)
            } else if event.clickCount == 2 {
                // Double-click a unit → select its same-type cluster (the first click already single-selected it).
                model?.doubleClickSelectSameType(tileX: x, tileY: y)
            } else {
                model?.leftClickTile(x, y)
            }
        }

        override public func rightMouseDown(with event: NSEvent) {
            if model?.missileTargeting != nil { model?.cancelMissileTargeting(); return }
            if model?.placement != nil { model?.cancelPlacement(); return }
            if let (x, y) = tile(at: event) {
                // A player building (with no units selected) opens its context popup; otherwise order units.
                let p = swiftUIPoint(event.location(in: self))
                if model?.rightClickOpensBuildingMenu(tileX: x, tileY: y, at: p) == true { return }
                model?.rightClickTile(x, y)
            }
        }

        /// A scene point in the SwiftUI map-overlay coordinate space (top-left origin) for popover anchoring.
        /// `convertPoint(toView:)` gives AppKit view coords (bottom-left), so flip y.
        private func swiftUIPoint(_ scenePoint: CGPoint) -> CGPoint {
            let v = convertPoint(toView: scenePoint)
            let h = view?.bounds.height ?? size.height
            return CGPoint(x: v.x, y: h - v.y)
        }

        /// Middle mouse button: drag to pan the map (a hand-tool — the content follows the cursor), or a plain
        /// click (no drag) recentres on the clicked point. Tracked in window coords so the camera's own motion
        /// during the drag doesn't feed back into the delta.
        override public func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }

            middleDragLastWindow = event.locationInWindow
            middleDidDrag = false
            middleDownScene = event.location(in: self)
        }

        override public func otherMouseDragged(with event: NSEvent) {
            guard event.buttonNumber == 2, let last = middleDragLastWindow else { return }

            let cur = event.locationInWindow
            let dx = Double(cur.x - last.x), dy = Double(cur.y - last.y)
            middleDragLastWindow = cur
            if dx != 0 || dy != 0 { middleDidDrag = true }
            // Hand-tool pan: drag right ⇒ content moves right (view pans left), drag up ⇒ content moves up.
            // `scroll` moves the content by `-dx` screen px / `+dy`; window y-up already matches the scroll `dy`.
            model?.scroll(dx: -dx, dy: dy)
        }

        override public func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else { return }

            defer { middleDragLastWindow = nil; middleDownScene = nil }
            if !middleDidDrag, let p = middleDownScene {
                model?.centerOn(worldX: Double(p.x), worldY: Double(Self.worldSidePx) - Double(p.y))
            }
        }

        override public func mouseMoved(with event: NSEvent) {
            lastMouseTile = tile(at: event)
            if model?.placement != nil, let (x, y) = lastMouseTile { model?.placementHover(tileX: x, tileY: y) }
            applyMapCursor()
        }

        override public func keyDown(with event: NSEvent) {
            // Control groups: Cmd+digit saves the current unit selection (slots + formation) under that digit;
            // the plain digit recalls it. Checked before the shortcut switch so the digits don't fall through.
            if let digit = controlGroupDigit(event) {
                if event.modifierFlags.contains(.command) {
                    model?.saveControlGroup(digit)
                } else {
                    model?.recallControlGroup(digit)
                }
                return
            }
            switch event.keyCode {
                case 24, 69: model?.zoomIn()  // '=' / '+' / keypad +
                case 27, 78: model?.zoomOut()  // '-' / keypad -
                case 123: model?.scroll(dx: -64, dy: 0)  // ←
                case 124: model?.scroll(dx: 64, dy: 0)  // →
                case 126: model?.scroll(dx: 0, dy: -64)  // ↑ (up = toward smaller image-y)
                case 125: model?.scroll(dx: 0, dy: 64)  // ↓
                case 49: model?.togglePause()  // space — pause / resume
                case 53:  // Esc — back out of whatever mode is active, else deselect
                    if model?.missileTargeting != nil {
                        model?.cancelMissileTargeting()
                    } else if model?.placement != nil {
                        model?.cancelPlacement()
                    } else {
                        model?.deselect()
                    }
                default:
                    // When a player **building** is selected, r/u/s drive its repair/upgrade (r and u toggle, so
                    // pressing them again stops; s stops whichever is in progress). Otherwise they're the per-unit
                    // action shortcuts — only the actions valid for that unit type fire (so `a`=Attack is ignored
                    // for a harvester, `r`=Return for a tank). Targeted actions (a/m/h) arm a crosshair click.
                    let building = model?.isBuildingSelected == true
                    switch event.charactersIgnoringModifiers?.lowercased() {
                        case "a": model?.issueAction(.attack)
                        case "m": model?.issueAction(.move)
                        case "h": model?.issueAction(.harvest)
                        case "r": if building { model?.repairSelected() } else { model?.issueAction(.return) }
                        case "u": model?.upgradeSelected()  // buildings only (no-op otherwise)
                        case "e": model?.issueAction(.retreat)
                        case "g": model?.issueAction(.guard_)
                        case "d": model?.issueAction(.deploy)
                        case "b": model?.issueAction(.sabotage)
                        case "x": model?.issueAction(.destruct)
                        case "s": if building { model?.stopBuildingActivity() } else { model?.stopSelected() }
                        case "l": model?.launchSuperWeapon()  // Palace super-weapon (no-op unless ready)
                        default: super.keyDown(with: event)
                    }
            }
        }

        /// The 0…9 control-group digit a key event names, or `nil`. Accepts a bare digit (recall) or Command+digit
        /// (save) — any other modifier (Option/Control/Shift) means it's a different chord, so we pass it through.
        private func controlGroupDigit(_ event: NSEvent) -> Int? {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.subtracting([ .command, .numericPad ]).isEmpty else { return nil }
            guard
                let chars = event.charactersIgnoringModifiers, chars.count == 1, let n = Int(chars),
                (0 ... 9).contains(n)
            else { return nil }

            return n
        }

        /// AppKit's authoritative cursor hook (fires as the mouse moves over the view), so our cursor sticks
        /// instead of AppKit resetting it to the arrow. Sets unconditionally — this is the per-move authority;
        /// the cheap change-gated path is `applyMapCursor` (driven by the frame loop for non-move changes).
        override public func cursorUpdate(with event: NSEvent) {
            lastMouseTile = tile(at: event)
            let kind = mapCursorKind()
            currentMapCursor = kind
            nsCursor(kind).set()
        }

        /// The cursor the map should show right now. An *armed* order (the `a`/`m`/`h`/`e` shortcut or a
        /// sidebar action button) dictates it for the whole "now pick a target" state: attack arms the reticle,
        /// the move-like orders the move pointer. Structure placement / palace target-select use the plain
        /// crosshair. Otherwise, with units selected, the attack reticle over an enemy and the move pointer over
        /// everything else (including fog of war); the plain arrow when nothing actionable is selected or the
        /// pointer is off the map.
        private func mapCursorKind() -> MapCursor {
            if let order = model?.pendingOrder { return order == .attack ? .attack : .move }
            if targetingActive { return .crosshair }
            guard let model, let t = lastMouseTile else { return .arrow }

            switch model.unitOrderIsAttack(tileX: t.x, tileY: t.y) {
                case true?: return .attack
                case false?: return .move
                case nil: return .arrow
            }
        }

        /// Apply the desired cursor, touching `NSCursor` only when its meaning changed.
        private func applyMapCursor() {
            let kind = mapCursorKind()
            guard kind != currentMapCursor else { return }

            currentMapCursor = kind
            nsCursor(kind).set()
        }

        private func nsCursor(_ kind: MapCursor) -> NSCursor {
            switch kind {
                case .arrow: return .arrow
                case .crosshair: return .crosshair
                // Authentic Dune II cursors: frame 0 is the pointer (move), frame 5 the target reticle (attack).
                case .move: return duneCursor(frame: 0, hotSpot: NSPoint(x: 0, y: 0)) ?? .arrow
                case .attack: return duneCursor(frame: 5, hotSpot: NSPoint(x: 8, y: 8)) ?? .crosshair
            }
        }

        /// An `NSCursor` from a `MOUSE.SHP` frame (index 0 transparent), built once and cached. `hotSpot` is in
        /// the OpenDUNE cursor coordinate space (top-left origin) — `cursorHotSpots` in `gui/viewport.c`. `nil`
        /// when the asset is missing (the caller falls back to a system cursor).
        private func duneCursor(frame: Int, hotSpot: NSPoint) -> NSCursor? {
            if let cached = duneCursorCache[frame] { return cached }
            guard
                let assets = model?.assets, let shp = assets.shp("MOUSE.SHP"), frame < shp.frames.count,
                case let f = shp.frames[frame],
                let cg = IndexedImage.cgImage(
                    indices: f.pixels,
                    width: f.width,
                    height: f.height,
                    palette: assets.palette,
                    transparentIndex: 0
                )
            else { return nil }

            let image = NSImage(cgImage: cg, size: NSSize(width: f.width, height: f.height))
            let cursor = NSCursor(image: image, hotSpot: hotSpot)
            duneCursorCache[frame] = cursor
            return cursor
        }
    #endif

    #if os(iOS)
        // MARK: - Touch input

        override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Ignore touches that originate in the screen-edge margin (system edge-swipes / accidental grips).
            if let t = touches.first, let v = view,
                    !v.bounds.insetBy(dx: Self.edgeMargin, dy: Self.edgeMargin).contains(t.location(in: v)) {
                return
            }
            let count = event?.allTouches?.count ?? touches.count
            if count >= 2 {
                // A second finger landed: stop panning and start a pinch from the fingers' current spread/zoom.
                cancelLongPress()
                pinchStartDistance = pinchDistance(event)
                pinchStartZoom = model?.viewport.zoom
                return
            }
            guard let t = touches.first else { return }

            let p = t.location(in: self)
            touchStartScene = p; touchLastScene = p; touchLastView = t.location(in: view)
            touchDidPan = false; longPressFired = false
            // Panning starts immediately (no settle delay) so a one-finger drag follows the finger right away;
            // if a second finger lands mid-drag, `touchesBegan`/`touchesMoved` switch to pinch-to-zoom.
            // A stationary long-press = the macOS right-click (default order / cancel a mode). Disabled during
            // structure placement, which has its own tap-to-place / tap-outside-to-cancel scheme.
            let work = DispatchWorkItem { [weak self] in
                guard
                    let self,
                    !self.touchDidPan,
                    self.model?.placement == nil,
                    let start = self.touchStartScene
                else { return }

                self.longPressFired = true
                if self.model?.missileTargeting != nil {
                    self.model?.cancelMissileTargeting()
                } else if let (x, y) = self.tile(atScenePoint: start) {
                    // A player building (with no units selected) opens its context popup; else order units.
                    // UIKit view coords are top-left already — no flip needed.
                    let p = self.convertPoint(toView: start)
                    if self.model?.rightClickOpensBuildingMenu(tileX: x, tileY: y, at: p) == true { return }
                    self.model?.rightClickTile(x, y)
                }
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Two fingers: continuous pinch-to-zoom (1×…8×), magnification tracking the finger spread.
            if (event?.allTouches?.count ?? touches.count) >= 2, let start = pinchStartDistance,
                    let startZoom = pinchStartZoom, let now = pinchDistance(event) {
                cancelLongPress()
                model?.setZoom(startZoom * Double(now / start))
                return
            }
            guard let t = touches.first else { return }

            let cur = t.location(in: self)
            let curView = t.location(in: view)
            defer { touchLastScene = cur; touchLastView = curView }
            if let start = touchStartScene, hypot(cur.x - start.x, cur.y - start.y) > 10 {
                touchDidPan = true; cancelLongPress()
            }
            // Placement: only a real *drag* (past the 10pt threshold) moves the footprint to follow the finger;
            // a tap's tiny jitter must not nudge it, so the tap places at the placeholder's current position.
            if model?.placement != nil {
                if touchDidPan, let (x, y) = tile(atScenePoint: cur) { model?.placementHover(tileX: x, tileY: y) }
                return
            }
            // Hand-tool pan: drag content with the finger 1:1 (view-space delta → `scroll`'s screen-point space),
            // unless a target-select / armed-order mode is active.
            if touchDidPan, let last = touchLastView,
                    model?.missileTargeting == nil, model?.pendingOrder == nil {
                model?.scroll(dx: -Double(curView.x - last.x), dy: -Double(curView.y - last.y))
            }
        }

        override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            defer { resetTouchState() }
            cancelLongPress()
            if pinchStartDistance != nil || longPressFired { return }
            guard let p = touchStartScene, let (x, y) = tile(atScenePoint: p) else { return }

            // Structure placement: a drag only repositioned the footprint (no commit on release). A *tap* on the
            // footprint commits the build there; a tap *outside* it cancels placement.
            if let pl = model?.placement {
                if touchDidPan { return }
                if pl.contains(tileX: x, tileY: y), let hx = pl.hoverTileX, let hy = pl.hoverTileY {
                    model?.placeAt(tileX: hx, tileY: hy)
                } else {
                    model?.cancelPlacement()
                }
                return
            }
            if touchDidPan { tapCount = 0; return }
            // A plain tap = the macOS left-click: launch in missile mode, else select / apply an armed order.
            if model?.missileTargeting != nil {
                model?.launchMissileAt(tileX: x, tileY: y)
            } else {
                let now = event?.timestamp ?? 0
                let repeated = now - lastTapTime < Self.doubleTapWindow && lastTapTile.map { $0 == (x, y) } == true
                tapCount = repeated ? tapCount + 1 : 1
                lastTapTime = now; lastTapTile = (x, y)
                // One tap selects; a same-tile second selects the same-type cluster; a third selects every
                // same-type unit on the map (then the count resets).
                switch tapCount {
                    case 1: model?.leftClickTile(x, y)
                    case 2: model?.doubleClickSelectSameType(tileX: x, tileY: y)
                    default:
                        model?.tripleClickSelectAllSameType(tileX: x, tileY: y)
                        lastTapTime = 0; lastTapTile = nil; tapCount = 0
                }
            }
        }

        override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            cancelLongPress(); resetTouchState()
        }

        /// The two-finger separation in **view (screen) points**. Must be view-space, not scene-space: scene
        /// coordinates scale with the camera, so measuring there feeds the changing zoom back into the distance
        /// and the magnification oscillates ("jiggles"). View points are zoom-independent, so the ratio tracks
        /// only the fingers' physical movement.
        private func pinchDistance(_ event: UIEvent?) -> CGFloat? {
            let pts = (event?.allTouches.map { Array($0) } ?? []).prefix(2).map { $0.location(in: view) }
            guard pts.count == 2 else { return nil }

            return hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)
        }

        private func cancelLongPress() { longPressWork?.cancel(); longPressWork = nil }

        private func resetTouchState() {
            touchStartScene = nil; touchLastScene = nil; touchLastView = nil; touchDidPan = false
            pinchStartDistance = nil; pinchStartZoom = nil
        }
    #endif
}
