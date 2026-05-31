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

    private weak var model: GameModel?
    private let cam = SKCameraNode()
    private var renderer: SpriteKitRenderer?
    private let selectionNode = SKShapeNode()
    private let healthLayer = SKNode()
    private var healthBars: [SKSpriteNode] = []
    private var stateChips: [SKSpriteNode] = []   // a small colour-coded action chip per health bar

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
        guard let model, let (tx, ty) = model.selectionTile() else { selectionNode.isHidden = true; return }
        let (w, h) = model.selectionFootprint()
        let originX = tx * Self.tileSize
        let topY = Self.worldSidePx - (ty + h) * Self.tileSize
        selectionNode.path = CGPath(rect: CGRect(x: originX, y: topY, width: w * Self.tileSize, height: h * Self.tileSize), transform: nil)
        selectionNode.isHidden = false
    }

    // MARK: - Health/state overlay (debug)

    private func updateHealth(_ frame: FrameInfo, show: Bool) {
        guard show else {
            for bar in healthBars { bar.isHidden = true }
            for chip in stateChips { chip.isHidden = true }
            return
        }
        var used = 0
        for unit in frame.units {
            let frac = unit.hitpointsMax > 0 ? Double(unit.hitpoints) / Double(unit.hitpointsMax) : 1
            let cx = unit.positionX * Self.tileSize / 256
            let barY = Double(Self.worldSidePx - unit.positionY * Self.tileSize / 256 + 10)   // above the sprite

            let bar = pooledBar(used)
            bar.size = CGSize(width: 14, height: 2)
            bar.position = CGPoint(x: Double(cx), y: barY)
            bar.color = frac > 0.66 ? .green : (frac > 0.33 ? .yellow : .red)
            bar.xScale = max(0.05, CGFloat(frac))
            bar.isHidden = false

            // A small state chip just in front of (left of) the bar; idle shows none.
            let chip = stateChips[used]
            if let colour = Self.activityColour(unit.activity) {
                chip.color = colour
                chip.position = CGPoint(x: Double(cx) - 4, y: barY)
                chip.isHidden = false
            } else {
                chip.isHidden = true
            }
            used += 1
        }
        for i in used ..< healthBars.count { healthBars[i].isHidden = true }
        for i in used ..< stateChips.count { stateChips[i].isHidden = true }
    }

    /// idle → no chip; otherwise a colour per the user's scheme.
    private static func activityColour(_ activity: FrameInfo.UnitActivity) -> NSColor? {
        switch activity {
            case .idle:       return nil
            case .attacking:  return .systemRed
            case .guarding:   return .systemBlue
            case .moving:     return .systemGreen
            case .harvesting: return .systemOrange
        }
    }

    private func pooledBar(_ i: Int) -> SKSpriteNode {
        while i >= healthBars.count {
            let bar = SKSpriteNode(color: .green, size: CGSize(width: 14, height: 2))
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            healthBars.append(bar); healthLayer.addChild(bar)
            let chip = SKSpriteNode(color: .systemBlue, size: CGSize(width: 4, height: 4))
            stateChips.append(chip); healthLayer.addChild(chip)
        }
        return healthBars[i]
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
