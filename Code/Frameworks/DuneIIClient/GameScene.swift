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
    static let worldSidePx = Int(Viewport.worldSize)   // 1024
    private static let tileSize = 16
    private static let barWidth = 7.0     // half the old 14 (user: "width 2x smaller")
    private static let barHeight = 1.0    // half the old 2 (user: "height 2x smaller")

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
    private let selectionLayer = SKNode()          // outline(s) around the selected unit(s)/structure
    private var selectionNodes: [SKShapeNode] = []   // pulsating square outline(s) for a selected building
    private var unitSelectNodes: [SKSpriteNode] = []   // the MOUSE.SHP[6] selection box around each selected unit
    private lazy var unitSelectTexture: SKTexture? = makeUnitSelectTexture()   // MOUSE/006, built once
    private let dragBoxNode = SKShapeNode()         // the drag-select rubber-band box
    // Left-drag (drag-select) gesture state.
    private var leftDragStartWindow: CGPoint?
    private var leftDragStartTile: (Int, Int)?
    private var leftDragging = false
    private let placementNode = SKShapeNode()      // structure-placement footprint preview
    #if os(macOS)
    private var trackingArea: NSTrackingArea?
    #endif
    // Middle-button pan/recentre state: the last cursor point (window coords, camera-independent), whether
    // this gesture moved, and the down point (scene coords) for a click-recentre.
    private var middleDragLastWindow: CGPoint?
    private var middleDidDrag = false
    private var middleDownScene: CGPoint?
    private var lastTargetingActive = false   // last cursor state, so we only `.set()` the cursor on change
    private let healthLayer = SKNode()
    private var healthBars: [SKSpriteNode] = []
    private var buildBars: [SKSpriteNode] = []   // a white production-progress bar under a building's health bar
    private var stateChips: [SKShapeNode] = []   // a small shape+colour action chip per unit health bar

    init(model: GameModel) {
        self.model = model
        super.init(size: CGSize(width: Self.worldSidePx, height: Self.worldSidePx))
        scaleMode = .resizeFill
        backgroundColor = .black
        addChild(cam)
        camera = cam
        selectionLayer.zPosition = 30
        addChild(selectionLayer)
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
        #if os(macOS)
        view.window?.acceptsMouseMovedEvents = true
        if trackingArea == nil {
            // `.activeAlways` (not `.activeInKeyWindow`): hover/cursor updates over the map keep working while
            // a floating tool window holds focus, matching the first-mouse click handling (`FirstMouseSKView`).
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                      owner: self)
            view.addTrackingArea(area)
            trackingArea = area
        }
        #endif
    }

    func load(simulation: Simulation, assets: AssetStore) {
        // Keep our overlay nodes — only drop the renderer's terrain/sprite nodes. (The placement-preview node
        // was being orphaned here, so its footprint never drew.)
        let keep: [SKNode] = [cam, selectionLayer, dragBoxNode, healthLayer, placementNode]
        for child in children where !keep.contains(child) { child.removeFromParent() }
        let r = SpriteKitRenderer(source: SpriteSource.make(assets: assets), basePalette: assets.palette,
                                  showFog: model?.showFog ?? false)
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
        model.viewSize = size                         // keep the model's view size current for clamping
        renderer.render(frame)
        applyViewport()
        updateSelection()
        updateHealth(frame, show: model.showHealthOverlay)
        updatePlacement()
        refreshCursor()
    }

    // MARK: - Placement preview

    /// Draw the structure-placement footprint at the hovered tile — green where valid, red where blocked.
    private func updatePlacement() {
        guard let model, let p = model.placement, let tx = p.hoverTileX, let ty = p.hoverTileY else {
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

    // MARK: - Selection outline

    private func updateSelection() {
        let boxes = model?.selectionBoxes() ?? []
        var usedSquares = 0, usedSprites = 0
        for box in boxes {
            if box.isStructure {
                // A building: a white square outline that pulsates (alpha 0↔1, 3 s period).
                let node = pooledSelectionSquare(usedSquares); usedSquares += 1
                let originX = box.centerX - box.width / 2
                let bottomY = Double(Self.worldSidePx) - (box.centerY + box.height / 2)   // image y-down → scene y-up
                node.path = CGPath(rect: CGRect(x: originX, y: bottomY, width: box.width, height: box.height), transform: nil)
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
            n.run(.repeatForever(.sequence([.fadeAlpha(to: 0, duration: 1.5), .fadeAlpha(to: 1, duration: 1.5)])),
                  withKey: "pulse")
            selectionNodes.append(n); selectionLayer.addChild(n)
        }
        return selectionNodes[i]
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
        guard let cg = IndexedImage.cgImage(indices: f.pixels, width: f.width, height: f.height,
                                            palette: assets.palette, transparentIndex: 0) else { return nil }
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
            if FrameComposer.isHiddenByFog(frame, worldX: unit.positionX, worldY: unit.positionY, showFog: fog) { continue }
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
            let (w, _) = Self.structureFootprint(s.type)
            let widthPx = Double(w) * tile
            let cornerX = Double(s.positionX) * tile / 256
            let cornerY = Double(s.positionY) * tile / 256
            let barW = max(8, widthPx - 4)
            let barLeft = cornerX + (widthPx - barW) / 2
            // `cornerY` is the building's top edge (image space); +1 puts the bar on its first row of pixels.
            let healthY = side - (cornerY + 1)
            placeBar(usedBars, left: barLeft, y: healthY, width: barW, frac: frac)
            usedBars += 1

            // A white production-progress bar directly under the health bar (same width/height/rules) while
            // the factory/CY is building or repairing something. `barHeight` lower in scene space = just below.
            if let progress = s.buildProgress {
                placeBuildBar(usedBuildBars, left: barLeft, y: healthY - Self.barHeight, width: barW, frac: progress)
                usedBuildBars += 1
            }
        }

        for i in usedBars ..< healthBars.count { healthBars[i].isHidden = true }
        for i in usedBuildBars ..< buildBars.count { buildBars[i].isHidden = true }
        for i in usedChips ..< stateChips.count { stateChips[i].isHidden = true }
    }

    /// A white build-progress bar (`buildBars` pool), same geometry + rules as `placeBar` but a fixed white
    /// colour: full width at 100% readiness, zero width at 0% — left-anchored, so it fills left→right.
    private func placeBuildBar(_ i: Int, left: Double, y: Double, width: Double, frac: Double) {
        while i >= buildBars.count {
            let bar = SKSpriteNode(color: .white, size: CGSize(width: Self.barWidth, height: Self.barHeight))
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            buildBars.append(bar); healthLayer.addChild(bar)
        }
        let bar = buildBars[i]
        let clamped = min(1, max(0, frac))
        bar.size = CGSize(width: width * clamped, height: Self.barHeight)
        bar.position = CGPoint(x: left, y: y)
        bar.color = .white
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
        let r = 1.25   // half the old 2.5 — the state icons are 2× smaller
        switch activity {
            case .idle: return nil
            case .moving:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -r, y: -r)); p.addLine(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: -r, y: r)); p.closeSubpath()
                return (p, .systemGreen)
            case .attacking:
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: r, y: 0))
                p.addLine(to: CGPoint(x: 0, y: -r)); p.addLine(to: CGPoint(x: -r, y: 0)); p.closeSubpath()
                return (p, .systemRed)
            case .guarding:
                return (CGPath(rect: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil), .systemBlue)
            case .harvesting:
                return (CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil), .systemOrange)
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
    private var targetingActive: Bool { (model?.pendingOrder != nil) || (model?.placement != nil) || (model?.missileTargeting != nil) }

    /// Set the crosshair while targeting, the arrow otherwise — only when the state changes. macOS only:
    /// iOS has no hardware cursor, so the body is a no-op there.
    private func refreshCursor() {
        guard targetingActive != lastTargetingActive else { return }
        lastTargetingActive = targetingActive
        #if os(macOS)
        (targetingActive ? NSCursor.crosshair : NSCursor.arrow).set()
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
        guard let start = leftDragStartWindow,
              model?.missileTargeting == nil, model?.placement == nil, model?.pendingOrder == nil else { return }
        let cur = event.locationInWindow
        if hypot(cur.x - start.x, cur.y - start.y) > 4 { leftDragging = true }
        if leftDragging, let from = leftDragStartTile, let to = tile(at: event) { setDragBox(from: from, to: to) }
    }

    override public func mouseUp(with event: NSEvent) {
        defer { leftDragStartWindow = nil; leftDragStartTile = nil; leftDragging = false; dragBoxNode.isHidden = true }
        if leftDragging, let from = leftDragStartTile, let to = tile(at: event) {
            model?.dragSelect(fromTileX: from.0, fromTileY: from.1, toTileX: to.0, toTileY: to.1)
            return
        }
        guard let (x, y) = tile(at: event) else { return }
        if model?.missileTargeting != nil { model?.launchMissileAt(tileX: x, tileY: y) }
        else if model?.placement != nil { model?.placeAt(tileX: x, tileY: y) }
        else { model?.leftClickTile(x, y) }
    }

    override public func rightMouseDown(with event: NSEvent) {
        if model?.missileTargeting != nil { model?.cancelMissileTargeting(); return }
        if model?.placement != nil { model?.cancelPlacement(); return }
        if let (x, y) = tile(at: event) { model?.rightClickTile(x, y) }
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
        guard model?.placement != nil, let (x, y) = tile(at: event) else { return }
        model?.placementHover(tileX: x, tileY: y)
    }

    override public func keyDown(with event: NSEvent) {
        switch event.keyCode {
            case 24, 69: model?.zoomIn()    // '=' / '+' / keypad +
            case 27, 78: model?.zoomOut()   // '-' / keypad -
            case 123: model?.scroll(dx: -64, dy: 0)   // ←
            case 124: model?.scroll(dx: 64, dy: 0)    // →
            case 126: model?.scroll(dx: 0, dy: -64)   // ↑ (up = toward smaller image-y)
            case 125: model?.scroll(dx: 0, dy: 64)    // ↓
            case 49:  model?.togglePause()   // space — pause / resume
            case 53:  // Esc — back out of whatever mode is active, else deselect
                if model?.missileTargeting != nil { model?.cancelMissileTargeting() }
                else if model?.placement != nil { model?.cancelPlacement() }
                else { model?.deselect() }
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
                    case "u": model?.upgradeSelected()   // buildings only (no-op otherwise)
                    case "e": model?.issueAction(.retreat)
                    case "g": model?.issueAction(.guard_)
                    case "d": model?.issueAction(.deploy)
                    case "b": model?.issueAction(.sabotage)
                    case "x": model?.issueAction(.destruct)
                    case "s": if building { model?.stopBuildingActivity() } else { model?.stopSelected() }
                    default:  super.keyDown(with: event)
                }
        }
    }

    /// AppKit's authoritative cursor hook (fires as the mouse moves over the view), so the crosshair sticks.
    override public func cursorUpdate(with event: NSEvent) {
        (targetingActive ? NSCursor.crosshair : NSCursor.arrow).set()
    }
    #endif
}
