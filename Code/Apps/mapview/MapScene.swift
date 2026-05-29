import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation
import SpriteKit

/// SpriteKit scene that draws a `GameState` and runs the basic game loop: each frame it advances the
/// `Simulation` clock (no unit logic yet) and re-colorizes the terrain through the palette animator, so
/// time-driven palette cycling (the windtrap power light, index 223) animates from real state.
@MainActor
final class MapScene: SKScene {
    private let cam = SKCameraNode()
    private var simulation: Simulation?
    private var assets: AssetStore?
    private var basePalette = AssetStore.grayscale
    private var terrainBuffer: [UInt8] = []
    private var terrainNode: SKSpriteNode?
    private var lastTick = -1

    func configure() {
        let side = CGFloat(MapImageBuilder.sidePx)
        size = CGSize(width: side, height: side)
        scaleMode = .aspectFit
        backgroundColor = SKColor.black
        addChild(cam)
        camera = cam
        cam.position = CGPoint(x: side / 2, y: side / 2)
    }

    func setZoom(_ factor: CGFloat) { cam.setScale(1 / max(factor, 1)) }

    func load(simulation: Simulation, assets: AssetStore) {
        self.simulation = simulation
        self.assets = assets
        basePalette = assets.palette
        for child in children where child !== cam { child.removeFromParent() }

        let side = MapImageBuilder.sidePx
        terrainBuffer = MapImageBuilder.terrainIndices(simulation.state, assets) ?? []
        let node = SKSpriteNode()
        node.position = CGPoint(x: side / 2, y: side / 2)
        node.zPosition = 0
        terrainNode = node
        addChild(node)
        recolorTerrain(tick: 0)

        for sprite in MapImageBuilder.unitSprites(simulation.state, assets) {
            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let unitNode = SKSpriteNode(texture: texture)
            unitNode.position = CGPoint(x: CGFloat(sprite.centerX), y: CGFloat(side - sprite.centerY))
            unitNode.zPosition = sprite.z
            addChild(unitNode)
        }
        lastTick = -1
    }

    /// The game loop: advance the simulation clock, then refresh the palette-cycled terrain.
    override func update(_ currentTime: TimeInterval) {
        guard simulation != nil else { return }
        simulation!.tick()
        let tick = Int(simulation!.state.timerGUI)
        if tick != lastTick {
            recolorTerrain(tick: tick)
            lastTick = tick
        }
    }

    private func recolorTerrain(tick: Int) {
        guard let terrainNode, !terrainBuffer.isEmpty else { return }
        let palette = PaletteAnimator.animatedPalette(base: basePalette, tick: tick)
        guard let image = MapImageBuilder.colorize(terrainBuffer, palette: palette) else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        terrainNode.texture = texture
        terrainNode.size = texture.size()
    }
}
