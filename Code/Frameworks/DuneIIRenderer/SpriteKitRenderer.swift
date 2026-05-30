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
    private var sidePx = 0

    // Palette cycling, advanced incrementally (O(1) per tick) rather than replayed from tick 0 each
    // frame (which is O(tick) and slows the longer the game runs).
    private var colors: [Palette.Color]
    private var cycle = PaletteAnimator.CycleState()
    private var lastTick = 0
    /// Whether the composed terrain actually uses the wind-trap index (223) — the only animated colour
    /// that appears in terrain/structure tiles, so terrain only needs a recolour when *it* moves.
    private var terrainHasWindIndex = false
    private var terrainDrawn = false

    public init(source: WorldSpriteSource, basePalette: Palette) {
        self.source = source
        self.basePalette = basePalette
        self.colors = basePalette.colors
    }

    /// The base side length in pixels of the composed world image (`terrainTileSize · 64`).
    public var worldSidePx: Int { source.terrainTileSize * 64 }

    /// Add the renderer's nodes to a scene once. The terrain sits at z 0, the sprites layer above it.
    public func attach(to scene: SKScene) {
        terrainNode.zPosition = 0
        if terrainNode.parent == nil { scene.addChild(terrainNode) }
        if spritesLayer.parent == nil { scene.addChild(spritesLayer) }
    }

    /// Draw one frame: advance the palette one tick at a time, recomposite the terrain only when its
    /// tiles changed, recolour it only when its tiles or the wind-trap colour actually changed (not every
    /// frame), and rebuild the moving sprites.
    public func render(_ frame: FrameInfo) {
        sidePx = source.terrainTileSize * frame.mapWidth
        let windChanged = advancePalette(to: Int(frame.tick))
        let palette = Palette(colors: colors)

        var terrainChanged = false
        if frame.tiles != lastTiles {
            terrainBuffer = FrameComposer.terrainBuffer(frame, source: source)
            lastTiles = frame.tiles
            terrainHasWindIndex = terrainBuffer.contains(UInt8(PaletteAnimator.windTrapIndex))
            terrainChanged = true
        }
        if terrainChanged || !terrainDrawn || (windChanged && terrainHasWindIndex) {
            if let image = IndexedImage.cgImage(indices: terrainBuffer, width: sidePx, height: sidePx,
                                                palette: palette) {
                terrainNode.texture = nearest(image)
                terrainNode.size = CGSize(width: sidePx, height: sidePx)
                terrainNode.position = CGPoint(x: sidePx / 2, y: sidePx / 2)
                terrainDrawn = true
            }
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

    /// Advance the cycling palette from `lastTick` to `tick`, one tick at a time (O(ticks elapsed),
    /// normally 1). Returns whether the wind-trap colour changed. Reseeds from base on a backward seek
    /// (a scenario reload), so the result still matches a fresh `animatedPalette(base:tick:)`.
    private func advancePalette(to tick: Int) -> Bool {
        guard colors.count > PaletteAnimator.selectionIndex else { return false }
        if tick < lastTick {
            colors = basePalette.colors
            cycle = PaletteAnimator.CycleState()
            lastTick = 0
        }
        guard tick > lastTick else { return false }
        let windBefore = colors[PaletteAnimator.windTrapIndex]
        for step in (lastTick + 1) ... tick {
            PaletteAnimator.stepTick(&colors, tick: step, state: &cycle)
        }
        lastTick = tick
        return colors[PaletteAnimator.windTrapIndex] != windBefore
    }

    private func nearest(_ image: CGImage) -> SKTexture {
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }
}
