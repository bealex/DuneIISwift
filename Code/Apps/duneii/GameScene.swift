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

    private weak var model: GameModel?
    private let cam = SKCameraNode()
    private var renderer: SpriteKitRenderer?
    private let selectionNode = SKShapeNode()
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
        healthLayer.zPosition = 40
        addChild(healthLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(simulation: Simulation, assets: AssetStore) {
        for child in children where child !== cam && child !== selectionNode && child !== healthLayer { child.removeFromParent() }
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
        guard let model, let renderer, let frame = model.advance() else { return }
        model.viewSize = size                         // keep the model's view size current for clamping
        renderer.render(frame)
        applyViewport()
        updateSelection()
        updateHealth(frame, show: model.showHealthOverlay)
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

    /// Health bars (+ unit state chips) over real units and buildings — never over bullets/rockets/effects.
    private func updateHealth(_ frame: FrameInfo, show: Bool) {
        guard show else { hideAllHealth(); return }
        let side = Double(Self.worldSidePx)
        let tile = Double(Self.tileSize)
        var usedBars = 0, usedChips = 0

        // Real units (projectiles skipped). Smooth sub-tile position; bar a little above the sprite centre.
        for unit in frame.units where !Self.projectileTypes.contains(unit.type) {
            let frac = unit.hitpointsMax > 0 ? Double(unit.hitpoints) / Double(unit.hitpointsMax) : 1
            let cx = Double(unit.positionX) * tile / 256
            let cy = Double(unit.positionY) * tile / 256
            let barLeft = cx - Self.barWidth / 2
            let barY = side - (cy - 10)
            placeBar(usedBars, left: barLeft, y: barY, width: Self.barWidth, frac: frac); usedBars += 1

            // A state chip (distinct shape + colour) just left of the bar; idle shows none.
            if let (path, colour) = Self.chipStyle(unit.activity) {
                let chip = pooledChip(usedChips); usedChips += 1
                chip.path = path; chip.fillColor = colour; chip.strokeColor = colour
                chip.position = CGPoint(x: barLeft - 4, y: barY)
                chip.isHidden = false
            }
        }

        // Buildings: a footprint-width bar along the top edge.
        for s in frame.structures {
            let frac = s.hitpointsMax > 0 ? Double(s.hitpoints) / Double(s.hitpointsMax) : 1
            let (w, _) = Self.structureFootprint(s.type)
            let widthPx = Double(w) * tile
            let cornerX = Double(s.positionX) * tile / 256
            let cornerY = Double(s.positionY) * tile / 256
            let barW = max(8, widthPx - 4)
            placeBar(usedBars, left: cornerX + (widthPx - barW) / 2, y: side - (cornerY - 3), width: barW, frac: frac)
            usedBars += 1
        }

        for i in usedBars ..< healthBars.count { healthBars[i].isHidden = true }
        for i in usedChips ..< stateChips.count { stateChips[i].isHidden = true }
    }

    private func placeBar(_ i: Int, left: Double, y: Double, width: Double, frac: Double) {
        let bar = pooledBar(i)
        bar.size = CGSize(width: width, height: Self.barHeight)
        bar.position = CGPoint(x: left, y: y)
        bar.color = frac > 0.66 ? .green : (frac > 0.33 ? .yellow : .red)
        bar.xScale = max(0.05, CGFloat(frac))   // depletes from the right (left-anchored)
        bar.isHidden = false
    }

    private func hideAllHealth() {
        for bar in healthBars { bar.isHidden = true }
        for chip in stateChips { chip.isHidden = true }
    }

    /// idle → no chip; otherwise a distinct **shape + colour** per state (centred on the node origin):
    /// move = green ▶ triangle, attack = red ◆ diamond, guard = blue ■ square, harvest = orange ● circle.
    private static func chipStyle(_ activity: FrameInfo.UnitActivity) -> (CGPath, NSColor)? {
        let r = 2.5
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

    override func mouseDown(with event: NSEvent) { if let (x, y) = tile(at: event) { model?.leftClickTile(x, y) } }
    override func rightMouseDown(with event: NSEvent) { if let (x, y) = tile(at: event) { model?.rightClickTile(x, y) } }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
            case 24, 69: model?.zoomIn()    // '=' / '+' / keypad +
            case 27, 78: model?.zoomOut()   // '-' / keypad -
            case 123: model?.scroll(dx: -64, dy: 0)   // ←
            case 124: model?.scroll(dx: 64, dy: 0)    // →
            case 126: model?.scroll(dx: 0, dy: -64)   // ↑ (up = toward smaller image-y)
            case 125: model?.scroll(dx: 0, dy: 64)    // ↓
            case 53:  model?.deselect()               // Esc
            default:  super.keyDown(with: event)
        }
    }

    private func tile(at event: NSEvent) -> (Int, Int)? {
        let p = event.location(in: self)     // scene = world coords (camera-adjusted)
        let x = Int(p.x) / Self.tileSize
        let y = (Self.worldSidePx - Int(p.y)) / Self.tileSize
        guard (0 ..< 64).contains(x), (0 ..< 64).contains(y) else { return nil }
        return (x, y)
    }
}
