import DuneIIScenarios
import Foundation
import SpriteKit

/// SpriteKit scene drawing a `ScenarioWorld`'s 8×8 region, ticking it each frame so behaviours animate
/// as the natives land. Terrain is re-blitted only when it changes; unit + effect sprites (explosions,
/// smoke) are rebuilt each frame from the sim state. The scenario's natural endpoint shows a banner
/// (and auto-pauses).
@MainActor
final class ScenarioScene: SKScene {
    private var world: ScenarioWorld?
    private var assets: ScenarioAssets?
    private var terrainNode: SKSpriteNode?
    private var spriteNodes: [SKSpriteNode] = []
    private var running = false
    /// Simulation speed: how many `tick()`s to run per rendered frame (1…10). The render only updates
    /// once per frame regardless, so higher values fast-forward the simulation without redrawing each tick.
    private var ticksPerFrame = 1

    /// The "scenario finished" banner, shown once when `outcome()` first reports done.
    private var bannerNode: SKNode?
    /// The scene time when the scenario was first detected as finished — the sim keeps running for
    /// `finishGraceSeconds` afterwards so death/destruction explosions + animations can play out, then
    /// auto-pauses. `nil` until the endpoint is reached.
    private var finishedAt: TimeInterval?
    private let finishGraceSeconds: TimeInterval = 5
    /// Called when the scenario reaches its endpoint (so the model can reflect the auto-pause in its UI).
    var onComplete: (@MainActor () -> Void)?

    /// The scene is exactly the 8×8 region in game pixels and maps square→square into a fixed-size view
    /// (the zoom is the view's point size — see `ContentView`), so it's never squished and stays
    /// point-to-pixel. No camera: `.aspectFit` maps the whole 128×128 scene into the (square) view.
    func configure() {
        let side = CGFloat(ScenarioImageBuilder.sidePx)
        size = CGSize(width: side, height: side)
        scaleMode = .aspectFit
        backgroundColor = .black
    }

    /// Load a freshly-built world and draw its initial frame. `running` controls whether `update` ticks.
    func load(world: ScenarioWorld, assets: ScenarioAssets, running: Bool) {
        self.world = world
        self.assets = assets
        self.running = running
        removeAllChildren()
        terrainNode = nil
        spriteNodes = []
        bannerNode = nil
        finishedAt = nil
        blitTerrain()
        rebuildSprites()
    }

    func setRunning(_ value: Bool) { running = value }

    /// Set the simulation speed (ticks run per rendered frame), clamped to 1…10.
    func setTicksPerFrame(_ value: Int) { ticksPerFrame = min(10, max(1, value)) }

    override func update(_ currentTime: TimeInterval) {
        guard running, var w = world else { return }
        // Advance the simulation `ticksPerFrame` times, then render once. `mapDirty` is only ever set by
        // `tick()` (cleared here), so after the loop it reflects whether any of those ticks dirtied terrain.
        for _ in 0 ..< ticksPerFrame { w.tick() }
        world = w
        if w.state.mapDirty {
            blitTerrain()
            world?.state.mapDirty = false
        }
        rebuildSprites()
        // The scenario reached its natural endpoint: flag it once (banner) but keep ticking for a short
        // grace period so the death/destruction explosions + animations finish, then auto-pause.
        if bannerNode == nil, case let .finished(label) = w.outcome() {
            showFinishedBanner(label)
            finishedAt = currentTime
        }
        if let finishedAt, currentTime - finishedAt >= finishGraceSeconds {
            self.finishedAt = nil
            running = false
            onComplete?()
        }
    }

    private func blitTerrain() {
        guard
            let world,
            let assets,
            let buffer = ScenarioImageBuilder.terrainIndices(world, assets),
            let image = ScenarioImageBuilder.colorize(buffer, palette: assets.palette)
        else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        if let terrainNode {
            terrainNode.texture = texture
            terrainNode.size = texture.size()
        } else {
            let node = SKSpriteNode(texture: texture)
            node.position = CGPoint(
                x: CGFloat(ScenarioImageBuilder.sidePx) / 2,
                y: CGFloat(ScenarioImageBuilder.sidePx) / 2
            )
            node.zPosition = 0
            addChild(node)
            terrainNode = node
        }
    }

    /// Rebuild the per-frame sprites: units + the transient effect sprites (explosions, smoke). Cheap —
    /// a handful of small textures — and the sim drives explosion animation via the sprite ids.
    private func rebuildSprites() {
        for node in spriteNodes { node.removeFromParent() }
        spriteNodes = []
        guard let world, let assets else { return }
        let side = ScenarioImageBuilder.sidePx
        let sprites =
            ScenarioImageBuilder.unitSprites(world, assets) + ScenarioImageBuilder.effectSprites(world, assets)
        for sprite in sprites {
            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture)
            node.position = CGPoint(x: CGFloat(sprite.centerX), y: CGFloat(side - sprite.centerY))  // flip y to scene space
            node.zPosition = sprite.z
            if sprite.flipped { node.xScale = -1 }
            addChild(node)
            spriteNodes.append(node)
        }
    }

    /// A top-of-scene "✓ <label>" banner shown once when the scenario finishes.
    private func showFinishedBanner(_ label: String) {
        let text = SKLabelNode(text: "✓ \(label)")
        text.fontName = "Helvetica-Bold"
        text.fontSize = 9
        text.fontColor = .white
        text.verticalAlignmentMode = .center
        text.horizontalAlignmentMode = .center

        let pad: CGFloat = 4
        let bg = SKShapeNode(
            rectOf: CGSize(
                width: text.frame.width + pad * 2,
                height: text.frame.height + pad * 2
            ),
            cornerRadius: 3
        )
        bg.fillColor = SKColor.black.withAlphaComponent(0.7)
        bg.strokeColor = .green
        bg.lineWidth = 1

        let container = SKNode()
        container.zPosition = 100
        container.position = CGPoint(
            x: CGFloat(ScenarioImageBuilder.sidePx) / 2,
            y: CGFloat(ScenarioImageBuilder.sidePx) - bg.frame.height
        )
        container.addChild(bg)
        container.addChild(text)
        addChild(container)
        bannerNode = container
    }
}
