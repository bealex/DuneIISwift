import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation
import SpriteKit

/// SpriteKit scene that draws a live `Simulation` through the engine's `FrameInfo` seam: each frame it
/// advances the sim one tick, snapshots a `FrameInfo`, and hands it to the library `SpriteKitRenderer`
/// (terrain + units + effects, palette-cycled, house-recoloured). The app no longer reaches into
/// `GameState` to draw — it consumes the same seam the Catalyst host will, proving it on real scenarios.
@MainActor
final class MapScene: SKScene {
    private static let worldSidePx = 16 * 64   // base scale: 16px tiles over the 64×64 map

    private let cam = SKCameraNode()
    private var simulation: Simulation?
    private var renderer: SpriteKitRenderer?

    func configure() {
        let side = CGFloat(Self.worldSidePx)
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
        for child in children where child !== cam { child.removeFromParent() }

        let renderer = SpriteKitRenderer(source: MapSpriteSource(assets: assets), basePalette: assets.palette)
        renderer.attach(to: self)
        renderer.render(simulation.makeFrameInfo())
        self.renderer = renderer
    }

    /// The game loop: advance the simulation (clocks + scripts + structure animations + explosions), then
    /// redraw from a fresh `FrameInfo` — units move/fire/die, bullets + soldiers appear, buildings animate
    /// + vanish when destroyed, and the windtrap power light pulses (palette cycling).
    override func update(_ currentTime: TimeInterval) {
        guard simulation != nil, let renderer else { return }
        simulation!.tick()
        renderer.render(simulation!.makeFrameInfo())
    }
}
