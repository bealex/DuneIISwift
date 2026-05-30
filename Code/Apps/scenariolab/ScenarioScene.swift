import DuneIIScenarios
import Foundation
import SpriteKit

/// SpriteKit scene drawing a `ScenarioWorld`'s 8×8 region, ticking it each frame so behaviours animate
/// as the natives land. Terrain is re-blitted only when it changes; unit sprites are rebuilt each tick
/// (a handful of small sprites).
@MainActor
final class ScenarioScene: SKScene {
    private var world: ScenarioWorld?
    private var assets: ScenarioAssets?
    private var terrainNode: SKSpriteNode?
    private var unitNodes: [SKSpriteNode] = []
    private var running = false
    /// Simulation speed: how many `tick()`s to run per rendered frame (1…10). The render only updates
    /// once per frame regardless, so higher values fast-forward the simulation without redrawing each tick.
    private var ticksPerFrame = 1

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
        unitNodes = []
        blitTerrain()
        rebuildUnits()
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
        rebuildUnits()
    }

    private func blitTerrain() {
        guard let world, let assets, let buffer = ScenarioImageBuilder.terrainIndices(world, assets),
              let image = ScenarioImageBuilder.colorize(buffer, palette: assets.palette) else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        if let terrainNode {
            terrainNode.texture = texture
            terrainNode.size = texture.size()
        } else {
            let node = SKSpriteNode(texture: texture)
            node.position = CGPoint(x: CGFloat(ScenarioImageBuilder.sidePx) / 2, y: CGFloat(ScenarioImageBuilder.sidePx) / 2)
            node.zPosition = 0
            addChild(node)
            terrainNode = node
        }
    }

    private func rebuildUnits() {
        for node in unitNodes { node.removeFromParent() }
        unitNodes = []
        guard let world, let assets else { return }
        let side = ScenarioImageBuilder.sidePx
        for sprite in ScenarioImageBuilder.unitSprites(world, assets) {
            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture)
            node.position = CGPoint(x: CGFloat(sprite.centerX), y: CGFloat(side - sprite.centerY))   // flip y to scene space
            node.zPosition = sprite.z
            if sprite.flipped { node.xScale = -1 }
            addChild(node)
            unitNodes.append(node)
        }
    }
}
