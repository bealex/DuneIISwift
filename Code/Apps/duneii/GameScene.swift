import AppKit
import DuneIIContracts
import DuneIIInput
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import SpriteKit

/// The map view: renders the live `Simulation` through `SpriteKitRenderer`, drives the camera from the
/// model's `Viewport` (scroll/zoom, pixel-perfect), forwards mouse/keyboard to the model (select/order,
/// +/- zoom, arrow scroll), and overlays the selection outline + (debug) per-unit health bars.
@MainActor
final class GameScene: SKScene {
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
    private let selectionNode = SKShapeNode()
    private let placementNode = SKShapeNode()      // structure-placement footprint preview
    private var trackingArea: NSTrackingArea?
    // Middle-button pan/recentre state: the last cursor point (window coords, camera-independent), whether
    // this gesture moved, and the down point (scene coords) for a click-recentre.
    private var middleDragLastWindow: CGPoint?
    private var middleDidDrag = false
    private var middleDownScene: CGPoint?
    private var lastTargetingActive = false   // last cursor state, so we only `.set()` the cursor on change
    private let healthLayer = SKNode()
    private var healthBars: [SKSpriteNode] = []
    private var stateChips: [SKShapeNode] = []   // a small shape+colour action chip per unit health bar

    init(model: GameModel) {
        self.model = model
        super.init(size: CGSize(width: Self.worldSidePx, height: Self.worldSidePx))
        scaleMode = .resizeFill
        backgroundColor = .black
        addChild(cam)
        camera = cam
        selectionNode.strokeColor = .white
        selectionNode.lineWidth = 1.5
        selectionNode.fillColor = .clear
        selectionNode.zPosition = 30
        selectionNode.isHidden = true
        addChild(selectionNode)
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
    override func didMove(to view: SKView) {
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
    }

    func load(simulation: Simulation, assets: AssetStore) {
        // Keep our overlay nodes — only drop the renderer's terrain/sprite nodes. (The placement-preview node
        // was being orphaned here, so its footprint never drew.)
        let keep: [SKNode] = [cam, selectionNode, healthLayer, placementNode]
        for child in children where !keep.contains(child) { child.removeFromParent() }
        let r = SpriteKitRenderer(source: SpriteSource.make(assets: assets), basePalette: assets.palette,
                                  showFog: model?.showFog ?? false)
        r.attach(to: self)
        r.render(simulation.makeFrameInfo())
        renderer = r
    }

    func applyFog() {
        guard let renderer, let frame = model?.lastFrame else { return }
        renderer.showFog = model?.showFog ?? false
        renderer.rebuildTerrain(frame)
    }

    override func update(_ currentTime: TimeInterval) {
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
        let colour: NSColor = valid ? .systemGreen : .systemRed
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
        guard let model, let box = model.selectionBox() else { selectionNode.isHidden = true; return }
        // Image space (y-down) → scene (y-up): the rect's bottom-left in scene coords.
        let originX = box.centerX - box.width / 2
        let bottomY = Double(Self.worldSidePx) - (box.centerY + box.height / 2)
        selectionNode.path = CGPath(rect: CGRect(x: originX, y: bottomY, width: box.width, height: box.height), transform: nil)
        selectionNode.isHidden = false
    }

    // MARK: - Health/state overlay

    /// Health bars (+ unit state chips) over real units and buildings — never over bullets/rockets/effects,
    /// and never over entities hidden in the fog (they aren't drawn, so neither is their bar).
    private func updateHealth(_ frame: FrameInfo, show: Bool) {
        guard show else { hideAllHealth(); return }
        let fog = model?.showFog ?? false
        let side = Double(Self.worldSidePx)
        let tile = Double(Self.tileSize)
        var usedBars = 0, usedChips = 0

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
            // `cornerY` is the building's top edge (image space); +1 puts the bar on its first row of pixels.
            placeBar(usedBars, left: cornerX + (widthPx - barW) / 2, y: side - (cornerY + 1), width: barW, frac: frac)
            usedBars += 1
        }

        for i in usedBars ..< healthBars.count { healthBars[i].isHidden = true }
        for i in usedChips ..< stateChips.count { stateChips[i].isHidden = true }
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
        for chip in stateChips { chip.isHidden = true }
    }

    /// idle → no chip; otherwise a distinct **shape + colour** per state (centred on the node origin):
    /// move = green ▶ triangle, attack = red ◆ diamond, guard = blue ■ square, harvest = orange ● circle.
    private static func chipStyle(_ activity: FrameInfo.UnitActivity) -> (CGPath, NSColor)? {
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

    override func mouseDown(with event: NSEvent) {
        guard let (x, y) = tile(at: event) else { return }
        if model?.missileTargeting != nil { model?.launchMissileAt(tileX: x, tileY: y) }
        else if model?.placement != nil { model?.placeAt(tileX: x, tileY: y) }
        else { model?.leftClickTile(x, y) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if model?.missileTargeting != nil { model?.cancelMissileTargeting(); return }
        if model?.placement != nil { model?.cancelPlacement(); return }
        if let (x, y) = tile(at: event) { model?.rightClickTile(x, y) }
    }

    /// Middle mouse button: drag to pan the map (a hand-tool — the content follows the cursor), or a plain
    /// click (no drag) recentres on the clicked point. Tracked in window coords so the camera's own motion
    /// during the drag doesn't feed back into the delta.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        middleDragLastWindow = event.locationInWindow
        middleDidDrag = false
        middleDownScene = event.location(in: self)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, let last = middleDragLastWindow else { return }
        let cur = event.locationInWindow
        let dx = Double(cur.x - last.x), dy = Double(cur.y - last.y)
        middleDragLastWindow = cur
        if dx != 0 || dy != 0 { middleDidDrag = true }
        // Hand-tool pan: drag right ⇒ content moves right (view pans left), drag up ⇒ content moves up.
        // `scroll` moves the content by `-dx` screen px / `+dy`; window y-up already matches the scroll `dy`.
        model?.scroll(dx: -dx, dy: dy)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        defer { middleDragLastWindow = nil; middleDownScene = nil }
        if !middleDidDrag, let p = middleDownScene {
            model?.centerOn(worldX: Double(p.x), worldY: Double(Self.worldSidePx) - Double(p.y))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard model?.placement != nil, let (x, y) = tile(at: event) else { return }
        model?.placementHover(tileX: x, tileY: y)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
            case 24, 69: model?.zoomIn()    // '=' / '+' / keypad +
            case 27, 78: model?.zoomOut()   // '-' / keypad -
            case 123: model?.scroll(dx: -64, dy: 0)   // ←
            case 124: model?.scroll(dx: 64, dy: 0)    // →
            case 126: model?.scroll(dx: 0, dy: -64)   // ↑ (up = toward smaller image-y)
            case 125: model?.scroll(dx: 0, dy: 64)    // ↓
            case 53:  // Esc — back out of whatever mode is active, else deselect
                if model?.missileTargeting != nil { model?.cancelMissileTargeting() }
                else if model?.placement != nil { model?.cancelPlacement() }
                else { model?.deselect() }
            default:
                // Order shortcuts on the selected unit: a/m/h/r arm a target-needing order (the cursor turns
                // into a crosshair; the next left-click supplies the target), s stops immediately.
                switch event.charactersIgnoringModifiers?.lowercased() {
                    case "a": model?.arm(.attack)
                    case "m": model?.arm(.move)
                    case "h": model?.arm(.harvest)
                    case "r": model?.arm(.retreat)
                    case "s": model?.stopSelected()
                    default:  super.keyDown(with: event)
                }
        }
    }

    // MARK: - Targeting cursor

    /// True while the next left-click supplies a target: an armed unit order, structure placement, or the
    /// palace death-hand target-select.
    private var targetingActive: Bool { (model?.pendingOrder != nil) || (model?.placement != nil) || (model?.missileTargeting != nil) }

    /// Set the crosshair while targeting, the arrow otherwise — only when the state changes (cheap each frame).
    private func refreshCursor() {
        guard targetingActive != lastTargetingActive else { return }
        lastTargetingActive = targetingActive
        (targetingActive ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    /// AppKit's authoritative cursor hook (fires as the mouse moves over the view), so the crosshair sticks.
    override func cursorUpdate(with event: NSEvent) {
        (targetingActive ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    private func tile(at event: NSEvent) -> (Int, Int)? {
        let p = event.location(in: self)     // scene = world coords (camera-adjusted)
        let x = Int(p.x) / Self.tileSize
        let y = (Self.worldSidePx - Int(p.y)) / Self.tileSize
        guard (0 ..< 64).contains(x), (0 ..< 64).contains(y) else { return nil }
        return (x, y)
    }
}
