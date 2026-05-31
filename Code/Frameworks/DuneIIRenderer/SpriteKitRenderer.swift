import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import SpriteKit

/// The SpriteKit presentation leaf: turns a `FrameInfo` into a drawn `SKScene`. It realizes the
/// `Renderer` seam shape (one `render(_:)` per frame) but is `@MainActor` and not a formal `Renderer`
/// conformance, so the headless `Renderer`/`NullRenderer` seam stays actor-agnostic.
///
/// **Everything that can be pre-rendered is, and cached in memory** (the per-frame cost was dominated by
/// re-colorizing the whole map + every sprite each frame):
/// - **Terrain is layered.** The static landscape is composited + colorized **once** into one background
///   node. Only the few cells that change over time — animating structure tiles, and tiles that use the
///   cycling wind-trap colour (index 223) — get a small overlay node on top, re-textured only when that
///   cell's tile id or the wind colour actually changes.
/// - **Tile + sprite textures are cached** by appearance: a `(tileId, windColour)` tile texture and a
///   `(spriteIndex, house)` sprite texture are colorized once and reused (the horizontal flip is a node
///   transform, not a separate texture). Palette-cycle variants accumulate in the cache, so after the
///   first cycle nothing is recolorized. Sprite nodes are pooled and repositioned, never reallocated.
///
/// Memory-heavy by design; the steady state does almost no CoreGraphics work. See `Architecture/Renderer.md`.
@MainActor
public final class SpriteKitRenderer {
    private let source: WorldSpriteSource
    private let basePalette: Palette

    private let terrainNode = SKSpriteNode()      // the static landscape, drawn once
    private let overlayLayer = SKNode()           // dynamic terrain cells (animations + wind light)
    private let spritesLayer = SKNode()           // units + effects (pooled nodes)

    // Caches (kept for the renderer's whole life — memory is cheap, recolorizing isn't).
    private struct TileKey: Hashable { let tileId: Int; let windColour: Int }
    private struct SpriteKey: Hashable { let index: Int; let house: Int; let flipped: Bool }
    private var tileCache: [TileKey: SKTexture] = [:]
    private var tileUsesWindCache: [Int: Bool] = [:]
    private var spriteCache: [SpriteKey: SKTexture] = [:]
    private var spritePool: [SKSpriteNode] = []

    // Dynamic-terrain bookkeeping.
    private var baselineGround: [Int] = []        // the tile id each cell shows in the static background
    private var displayedGround: [Int] = []       // the tile id each cell currently shows (overlay or base)
    private var windCells: Set<Int> = []          // cells whose tile uses the wind-trap colour (223)
    private var overlayNodes: [Int: SKSpriteNode] = [:]
    private var initialized = false

    // Palette cycling, advanced incrementally (O(1) per tick).
    private var colours: [Palette.Color]
    private var cycle = PaletteAnimator.CycleState()
    private var lastTick = 0
    private var lastWindColour = -1
    private var tileSize = 16
    private var mapWidth = 64

    public init(source: WorldSpriteSource, basePalette: Palette) {
        self.source = source
        self.basePalette = basePalette
        var seeded = basePalette.colors
        PaletteAnimator.seedAnimatedColours(&seeded)    // no magenta windtrap-light flash at tick 0 (#4)
        self.colours = seeded
    }

    public var worldSidePx: Int { source.terrainTileSize * 64 }

    /// Add the renderer's nodes to a scene once (static terrain at z 0, dynamic overlay above it, sprites on top).
    public func attach(to scene: SKScene) {
        terrainNode.zPosition = 0
        overlayLayer.zPosition = 1
        spritesLayer.zPosition = 10
        for node in [terrainNode as SKNode, overlayLayer, spritesLayer] where node.parent == nil {
            scene.addChild(node)
        }
    }

    /// Draw one frame: advance the palette, build the static background + dynamic-cell set once, then per
    /// frame touch only the terrain cells that changed and reposition the (cached-texture) sprites.
    public func render(_ frame: FrameInfo) {
        tileSize = source.terrainTileSize
        mapWidth = frame.mapWidth
        advancePalette(to: Int(frame.tick))
        let palette = Palette(colors: colours)
        let windColour = packedWindColour()

        if !initialized {
            buildStaticBackground(frame, palette: palette)
            initialized = true
        }
        updateDynamicTerrain(frame, palette: palette, windColour: windColour)
        updateSprites(frame, palette: palette)
        lastWindColour = windColour
    }

    // MARK: - Terrain

    private func buildStaticBackground(_ frame: FrameInfo, palette: Palette) {
        let side = tileSize * frame.mapWidth
        let buffer = FrameComposer.terrainBuffer(frame, source: source)
        if let image = IndexedImage.cgImage(indices: buffer, width: side, height: side, palette: palette) {
            terrainNode.texture = nearest(image)
            terrainNode.size = CGSize(width: side, height: side)
            terrainNode.position = CGPoint(x: side / 2, y: side / 2)
        }
        baselineGround = frame.tiles.map { $0.groundSpriteIndex }
        displayedGround = baselineGround
        windCells = []
        for i in baselineGround.indices where tileUsesWind(baselineGround[i]) { windCells.insert(i) }
    }

    private func updateDynamicTerrain(_ frame: FrameInfo, palette: Palette, windColour: Int) {
        // The cells to revisit this frame: any whose tile id changed, plus every wind cell when the
        // wind-trap colour moved. Everything else is already correct on the static background.
        var dirty: Set<Int> = []
        let n = min(frame.tiles.count, displayedGround.count)
        for i in 0 ..< n where frame.tiles[i].groundSpriteIndex != displayedGround[i] { dirty.insert(i) }
        if windColour != lastWindColour { dirty.formUnion(windCells) }

        for i in dirty {
            let tileId = frame.tiles[i].groundSpriteIndex
            displayedGround[i] = tileId
            if tileUsesWind(tileId) { windCells.insert(i) } else { windCells.remove(i) }

            // A cell needs an overlay when it differs from the static background or pulses with the wind.
            if tileId != baselineGround[i] || windCells.contains(i) {
                guard let texture = tileTexture(tileId, palette: palette) else { continue }
                let node = overlayNodes[i] ?? makeCellNode(i)
                node.texture = texture
                overlayNodes[i] = node
            } else if let node = overlayNodes.removeValue(forKey: i) {
                node.removeFromParent()
            }
        }
    }

    private func makeCellNode(_ cell: Int) -> SKSpriteNode {
        let node = SKSpriteNode()
        node.size = CGSize(width: tileSize, height: tileSize)
        let tx = cell % mapWidth, ty = cell / mapWidth
        let side = tileSize * mapWidth
        // Image space is y-down; the scene is y-up. Cell centre.
        node.position = CGPoint(x: tx * tileSize + tileSize / 2,
                                y: side - (ty * tileSize + tileSize / 2))
        overlayLayer.addChild(node)
        return node
    }

    private func tileTexture(_ tileId: Int, palette: Palette) -> SKTexture? {
        let usesWind = tileUsesWind(tileId)
        let key = TileKey(tileId: tileId, windColour: usesWind ? packedWindColour() : 0)
        if let cached = tileCache[key] { return cached }
        guard let pixels = source.terrainTile(tileId),
              let image = IndexedImage.cgImage(indices: pixels, width: tileSize, height: tileSize,
                                               palette: palette) else { return nil }
        let texture = nearest(image)
        tileCache[key] = texture
        return texture
    }

    private func tileUsesWind(_ tileId: Int) -> Bool {
        if let cached = tileUsesWindCache[tileId] { return cached }
        let uses = source.terrainTile(tileId)?.contains(UInt8(PaletteAnimator.windTrapIndex)) ?? false
        tileUsesWindCache[tileId] = uses
        return uses
    }

    // MARK: - Sprites

    private func updateSprites(_ frame: FrameInfo, palette: Palette) {
        let sprites = FrameComposer.sprites(frame, source: source)
        let side = tileSize * frame.mapWidth
        var used = 0
        for sprite in sprites {
            guard let texture = spriteTexture(sprite, palette: palette) else { continue }
            let node = pooledSprite(used); used += 1
            node.texture = texture
            node.size = texture.size()
            node.position = CGPoint(x: CGFloat(sprite.centerX), y: CGFloat(side - sprite.centerY))
            node.zPosition = CGFloat(sprite.z)
            node.xScale = 1                                  // the mirror is baked into the texture, not a transform
            node.isHidden = false
        }
        for i in used ..< spritePool.count { spritePool[i].isHidden = true }
    }

    private func spriteTexture(_ sprite: ComposedSprite, palette: Palette) -> SKTexture? {
        let key = SpriteKey(index: sprite.spriteIndex, house: sprite.house?.rawValue ?? -1,
                            flipped: sprite.flipped)
        if let cached = spriteCache[key] { return cached }
        let remap: (UInt8) -> UInt8 = sprite.house.map { house in { HouseRemap.sprite($0, house: house) } }
            ?? { $0 }
        // Bake the horizontal mirror into the pixels (the W-half sprites are the E-half mirrored) rather
        // than relying on a node `xScale = -1` transform — pre-rendered, and immune to any transform quirk.
        let pixels = sprite.flipped
            ? Self.mirrorRows(sprite.frame.pixels, width: sprite.frame.width, height: sprite.frame.height)
            : sprite.frame.pixels
        guard let image = IndexedImage.cgImage(indices: pixels, width: sprite.frame.width,
                                               height: sprite.frame.height, palette: palette,
                                               transparentIndex: 0, remap: remap) else { return nil }
        let texture = nearest(image)
        spriteCache[key] = texture
        return texture
    }

    /// A row-major indexed buffer mirrored left↔right (each row reversed).
    nonisolated static func mirrorRows(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height else { return pixels }
        var out = pixels
        for y in 0 ..< height {
            let row = y * width
            for x in 0 ..< width { out[row + x] = pixels[row + (width - 1 - x)] }
        }
        return out
    }

    private func pooledSprite(_ i: Int) -> SKSpriteNode {
        if i < spritePool.count { return spritePool[i] }
        let node = SKSpriteNode()
        spritePool.append(node)
        spritesLayer.addChild(node)
        return node
    }

    // MARK: - Palette

    /// Advance the cycling palette from `lastTick` to `tick`, one tick at a time (O(ticks elapsed),
    /// normally 1). Reseeds from base on a backward seek (a scenario reload).
    private func advancePalette(to tick: Int) {
        guard colours.count > PaletteAnimator.selectionIndex else { return }
        if tick < lastTick {
            colours = basePalette.colors
            PaletteAnimator.seedAnimatedColours(&colours)
            cycle = PaletteAnimator.CycleState()
            lastTick = 0
        }
        guard tick > lastTick else { return }
        for step in (lastTick + 1) ... tick {
            PaletteAnimator.stepTick(&colours, tick: step, state: &cycle)
        }
        lastTick = tick
    }

    private func packedWindColour() -> Int {
        guard colours.count > PaletteAnimator.windTrapIndex else { return 0 }
        let c = colours[PaletteAnimator.windTrapIndex]
        return (Int(c.red) << 16) | (Int(c.green) << 8) | Int(c.blue)
    }

    private func nearest(_ image: CGImage) -> SKTexture {
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }
}
