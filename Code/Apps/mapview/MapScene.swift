import DuneIIWorld
import Foundation
import SpriteKit

/// SpriteKit scene that draws a `GameState`: one terrain+structures tile node (`ICON.ICN` tiles), and
/// one node per unit (its SHP sprite). A camera provides the 1×–16× zoom; the scene fits the window.
@MainActor
final class MapScene: SKScene {
    private let cam = SKCameraNode()

    func configure() {
        let side = CGFloat(MapImageBuilder.sidePx)
        size = CGSize(width: side, height: side)
        scaleMode = .aspectFit
        backgroundColor = SKColor.black
        addChild(cam)
        camera = cam
        cam.position = CGPoint(x: side / 2, y: side / 2)
    }

    /// Zoom factor: 1 fits the whole map, higher zooms into the centre.
    func setZoom(_ factor: CGFloat) { cam.setScale(1 / max(factor, 1)) }

    func rebuild(state: GameState, assets: AssetStore) {
        for child in children where child !== cam { child.removeFromParent() }

        let side = MapImageBuilder.sidePx

        if let terrain = MapImageBuilder.terrainImage(state, assets) {
            let texture = SKTexture(cgImage: terrain)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture)
            node.position = CGPoint(x: side / 2, y: side / 2)   // image origin top-left → centre
            node.zPosition = 0
            addChild(node)
        }

        for sprite in MapImageBuilder.unitSprites(state, assets) {
            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture)
            // image space is y-down; SpriteKit is y-up.
            node.position = CGPoint(x: CGFloat(sprite.centerX), y: CGFloat(side - sprite.centerY))
            node.zPosition = 1
            addChild(node)
        }
    }
}
