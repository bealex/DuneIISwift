import DuneIIScenarios
import Foundation
import SpriteKit

/// SpriteKit scene drawing a `ScenarioWorld`'s 8×8 region, ticking it each frame so behaviours animate
/// as the natives land. Terrain is re-blitted only when it changes; unit sprites are rebuilt each tick
/// (a handful of small sprites).
@MainActor
final class ScenarioScene: SKScene {
    private let cam = SKCameraNode()
    private var world: ScenarioWorld?
    private var assets: ScenarioAssets?
    private var terrainNode: SKSpriteNode?
    private var unitNodes: [SKSpriteNode] = []
    private var running = false

    func configure() {
        let side = CGFloat(ScenarioImageBuilder.sidePx)
        size = CGSize(width: side, height: side)
        scaleMode = .aspectFit
        backgroundColor = .black
        addChild(cam)
        camera = cam
        cam.position = CGPoint(x: side / 2, y: side / 2)
    }

    func setZoom(_ factor: CGFloat) { cam.setScale(1 / max(factor, 1)) }

    /// Load a freshly-built world and draw its initial frame. `running` controls whether `update` ticks.
    func load(world: ScenarioWorld, assets: ScenarioAssets, running: Bool) {
        self.world = world
        self.assets = assets
        self.running = running
        for child in children where child !== cam { child.removeFromParent() }
        terrainNode = nil
        unitNodes = []
        blitTerrain()
        rebuildUnits()
    }

    func setRunning(_ value: Bool) { running = value }

    override func update(_ currentTime: TimeInterval) {
        guard running, var w = world else { return }
        let dirtyBefore = w.state.mapDirty
        w.tick()
        world = w
        if dirtyBefore || w.state.mapDirty {
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
