import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import SpriteKit

/// The SpriteKit presentation leaf: turns a `FrameInfo` into a drawn `SKScene`. It realizes the
/// `Renderer` seam shape (one `render(_:)` per frame) but is `@MainActor` and not a formal `Renderer`
/// conformance, so the headless `Renderer`/`NullRenderer` seam stays actor-agnostic.
///
/// Composition is the pure `FrameComposer`; this leaf only colorizes (palette + `HouseRemap`) and lays
/// the result into two nodes — one terrain `SKSpriteNode` (the full 64×64 map, nearest-filtered) and a
/// sprites layer rebuilt each frame (units + effects). The whole world is drawn at base scale (16px
/// tiles); zoom + scroll are a camera transform the host owns. Mirrors `mapview`'s old `MapScene` draw,
/// now driven by the seam instead of reaching into `GameState`. See `Architecture/Renderer.md`.
@MainActor
public final class SpriteKitRenderer {
    private let source: WorldSpriteSource
    private let basePalette: Palette

    private let terrainNode = SKSpriteNode()
    private let spritesLayer = SKNode()

    private var terrainBuffer: [UInt8] = []
    private var lastTiles: [FrameInfo.Tile] = []
    private var lastPaletteTick = -1
    private var sidePx = 0

    public init(source: WorldSpriteSource, basePalette: Palette) {
        self.source = source
        self.basePalette = basePalette
    }

    /// The base side length in pixels of the composed world image (`terrainTileSize · 64`).
    public var worldSidePx: Int { source.terrainTileSize * 64 }

    /// Add the renderer's nodes to a scene once. The terrain sits at z 0, the sprites layer above it.
    public func attach(to scene: SKScene) {
        terrainNode.zPosition = 0
        if terrainNode.parent == nil { scene.addChild(terrainNode) }
        if spritesLayer.parent == nil { scene.addChild(spritesLayer) }
    }

    /// Draw one frame: recomposite the terrain only when its tiles changed, recolour it on a
    /// palette-cycle tick change (the windtrap light etc.), and rebuild the moving sprites every frame.
    public func render(_ frame: FrameInfo) {
        sidePx = source.terrainTileSize * frame.mapWidth
        let palette = PaletteAnimator.animatedPalette(base: basePalette, tick: Int(frame.tick))

        if frame.tiles != lastTiles {
            terrainBuffer = FrameComposer.terrainBuffer(frame, source: source)
            lastTiles = frame.tiles
            lastPaletteTick = -1                       // force a recolour after a re-composite
        }
        if Int(frame.tick) != lastPaletteTick {
            if let image = IndexedImage.cgImage(indices: terrainBuffer, width: sidePx, height: sidePx,
                                                palette: palette) {
                terrainNode.texture = nearest(image)
                terrainNode.size = CGSize(width: sidePx, height: sidePx)
                terrainNode.position = CGPoint(x: sidePx / 2, y: sidePx / 2)
            }
            lastPaletteTick = Int(frame.tick)
        }

        spritesLayer.removeAllChildren()
        for sprite in FrameComposer.sprites(frame, source: source) {
            let remap: (UInt8) -> UInt8 = sprite.house.map { house in { HouseRemap.sprite($0, house: house) } }
                ?? { $0 }
            guard let image = IndexedImage.cgImage(indices: sprite.frame.pixels, width: sprite.frame.width,
                                                   height: sprite.frame.height, palette: palette,
                                                   transparentIndex: 0, remap: remap) else { continue }
            let node = SKSpriteNode(texture: nearest(image))
            // Image space is y-down; the scene is y-up.
            node.position = CGPoint(x: CGFloat(sprite.centerX), y: CGFloat(sidePx - sprite.centerY))
            node.zPosition = CGFloat(sprite.z)
            if sprite.flipped { node.xScale = -1 }     // W-half sprites are the E-half mirrored
            spritesLayer.addChild(node)
        }
    }

    private func nearest(_ image: CGImage) -> SKTexture {
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }
}
