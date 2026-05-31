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
    private let blurLayer = SKNode()              // sandworm shimmer patches (terrain displacement)
    private let spritesLayer = SKNode()           // units + effects (pooled nodes)

    // Caches (kept for the renderer's whole life — memory is cheap, recolorizing isn't).
    private struct TileKey: Hashable { let tileId: Int; let overlayId: Int; let houseID: UInt8; let windColour: Int; let fog: Bool }
    private struct SpriteKey: Hashable { let index: Int; let house: Int; let flipped: Bool; let flippedV: Bool }
    private var tileCache: [TileKey: SKTexture] = [:]
    private var tileUsesWindCache: [Int: Bool] = [:]
    private var spriteCache: [SpriteKey: SKTexture] = [:]
    private var spritePool: [SKSpriteNode] = []

    /// Whether to render fog of war (black out veiled cells). Off by default — the verification UI shows
    /// the whole landscape (OpenDUNE's "debug scenario" view); flip on to verify fog-reveal behaviour.
    public var showFog: Bool
    private var veiledTileIndex = 0

    // Dynamic-terrain bookkeeping. Each cell's appearance is (ground, overlay, house); a cell gets a small
    // overlay node when it differs from the static background or pulses with the wind.
    private struct CellAppearance: Equatable { var ground: Int; var overlay: Int; var house: UInt8; var fogEdge: Int }
    private var baseline: [CellAppearance] = []   // what each cell shows in the static background
    private var displayed: [CellAppearance] = []  // what each cell currently shows (overlay node or base)
    private var windCells: Set<Int> = []          // cells whose tile uses the wind-trap colour (223)
    private var overlayNodes: [Int: SKSpriteNode] = [:]
    private var initialized = false

    // Sandworm shimmer: the static indexed terrain (sampled per worm) + a pool of displacement nodes, and
    // the per-frame blur offset cursor (`s_blurIndex`, cycling `ShimmerEffect.blurOffsets`).
    private var terrainIndices: [UInt8] = []
    private var blurPool: [SKSpriteNode] = []
    private var blurIndex = 0

    // Palette cycling, advanced incrementally (O(1) per tick).
    private var colours: [Palette.Color]
    private var cycle = PaletteAnimator.CycleState()
    private var lastTick = 0
    private var lastWindColour = -1
    private var tileSize = 16
    private var mapWidth = 64

    public init(source: WorldSpriteSource, basePalette: Palette, showFog: Bool = false) {
        self.source = source
        self.basePalette = basePalette
        self.showFog = showFog
        var seeded = basePalette.colors
        PaletteAnimator.seedAnimatedColours(&seeded)    // no magenta windtrap-light flash at tick 0 (#4)
        self.colours = seeded
    }

    public var worldSidePx: Int { source.terrainTileSize * 64 }

    /// A lazily-built off-screen scene the renderer's nodes are attached to for `snapshot(_:crop:)`. A node
    /// has one parent, so once a renderer is used for capture it must not also be `attach`ed to a live app
    /// scene (and vice versa) — capture renderers are dedicated.
    private var captureScene: SKScene?

    /// Render `frame` through the real pipeline and capture the result as a `CGImage` — the whole 64×64
    /// world at base scale (`worldSidePx` square), optionally cropped to an **image-space** rect (origin
    /// top-left, y-down; e.g. tile `(tx,ty)` of size `(w,h)` is `CGRect(tx·ts, ty·ts, w·ts, h·ts)` with
    /// `ts = terrainTileSize`). This drives the *same* nodes/textures/z-order/palette/fog as the on-screen
    /// renderer (it is the real renderer, not a parallel rasterizer), so a headless run can pause at any
    /// tick and snapshot any region for a rendering test or a reference PNG. Returns `nil` if the platform
    /// can't provide an off-screen GPU context (e.g. a no-GPU CI box) — SpriteKit-backed, so it runs on a
    /// real Mac. The typical headless flow keeps a `NullRenderer` for the run and swaps in a dedicated
    /// `SpriteKitRenderer` only to capture.
    public func snapshot(_ frame: FrameInfo, crop: CGRect? = nil) -> CGImage? {
        let side = CGFloat(worldSidePx)
        let scene: SKScene
        if let captureScene {
            scene = captureScene
        } else {
            let s = SKScene(size: CGSize(width: side, height: side))
            s.anchorPoint = .zero
            s.scaleMode = .fill
            s.backgroundColor = .black
            attach(to: s)
            captureScene = s
            scene = s
        }
        render(frame)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        guard let texture = view.texture(from: scene) else { return nil }
        let full = texture.cgImage()
        guard let crop else { return full }
        // `texture(from:)` rasterizes at the host backing scale (2× on a Retina display), so the CGImage is
        // larger than the logical `side`. `crop` is in logical points (image-space, y-down) — scale it to
        // pixels by the measured ratio so the requested tile region is captured at any backing scale.
        let scale = CGFloat(full.width) / side
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                            width: crop.width * scale, height: crop.height * scale)
        return full.cropping(to: pixels)
    }

    /// Add the renderer's nodes to a scene once (static terrain at z 0, dynamic overlay above it, sprites on top).
    public func attach(to scene: SKScene) {
        terrainNode.zPosition = 0
        overlayLayer.zPosition = 1
        blurLayer.zPosition = 2          // worm shimmer sits on the terrain, under the unit sprites
        spritesLayer.zPosition = 10
        for node in [terrainNode as SKNode, overlayLayer, blurLayer, spritesLayer] where node.parent == nil {
            scene.addChild(node)
        }
    }

    /// Force the static terrain layer to recomposite on the next render — call after changing `showFog`
    /// (or any map-wide render setting) so the change takes effect. Drops the dynamic overlay nodes (they
    /// rebuild from the fresh baseline) and redraws immediately.
    public func rebuildTerrain(_ frame: FrameInfo) {
        for node in overlayNodes.values { node.removeFromParent() }
        overlayNodes.removeAll()
        initialized = false
        render(frame)
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
        updateBlurs(frame, palette: palette)
        lastWindColour = windColour
    }

    // MARK: - Terrain

    private func appearance(_ tile: FrameInfo.Tile) -> CellAppearance {
        // A cell's appearance for incremental repaint. The fog **edge** (the dithered soft boundary on a
        // revealed tile bordering the unknown) must be tracked so a tile repaints when a *neighbour* is
        // revealed and its edge changes — without it the soft edges go stale as units move. Only when
        // `showFog`; off, the edge isn't drawn so it's pinned to 0.
        // The binary veil (`overlay == veiledTileIndex`, a black cell) is already tracked via `overlay`; but
        // with fog OFF a veiled overlay renders as plain ground (`cell()` skips it), so normalise it to 0 so
        // a continuous fog reveal doesn't needlessly dirty every tile a unit drives past in the no-fog view.
        let overlay = (!showFog && tile.overlaySpriteIndex == veiledTileIndex) ? 0 : tile.overlaySpriteIndex
        return CellAppearance(ground: tile.groundSpriteIndex, overlay: overlay, house: tile.houseID,
                              fogEdge: showFog ? tile.fogEdgeSpriteIndex : 0)
    }

    private func buildStaticBackground(_ frame: FrameInfo, palette: Palette) {
        veiledTileIndex = frame.veiledTileIndex
        let side = tileSize * frame.mapWidth
        let buffer = FrameComposer.terrainBuffer(frame, source: source, showFog: showFog)
        if let image = IndexedImage.cgImage(indices: buffer, width: side, height: side, palette: palette) {
            terrainNode.texture = nearest(image)
            terrainNode.size = CGSize(width: side, height: side)
            terrainNode.position = CGPoint(x: side / 2, y: side / 2)
        }
        terrainIndices = buffer                 // kept for the worm-shimmer terrain displacement
        baseline = frame.tiles.map(appearance)
        displayed = baseline
        windCells = []
        for i in baseline.indices where tileUsesWind(baseline[i].ground) { windCells.insert(i) }
    }

    private func updateDynamicTerrain(_ frame: FrameInfo, palette: Palette, windColour: Int) {
        // The cells to revisit this frame: any whose appearance (ground / overlay / house) changed, plus
        // every wind cell when the wind-trap colour moved. Everything else is already correct on the static
        // background.
        var dirty: Set<Int> = []
        let n = min(frame.tiles.count, displayed.count)
        for i in 0 ..< n where appearance(frame.tiles[i]) != displayed[i] { dirty.insert(i) }
        if windColour != lastWindColour { dirty.formUnion(windCells) }

        for i in dirty {
            let app = appearance(frame.tiles[i])
            displayed[i] = app
            if tileUsesWind(app.ground) { windCells.insert(i) } else { windCells.remove(i) }

            // A cell needs an overlay node when it differs from the static background or pulses with the wind.
            // Once a cell has *ever* been dynamic we LATCH its overlay node — when it cycles back to the
            // baseline appearance we keep the node (re-textured to the baseline tile) instead of removing it.
            // Removing it hands the cell back to the big static-terrain texture, and the two render paths
            // (per-cell 16px node vs. the map-sized background) don't land on exactly the same pixels under a
            // fractional camera at zoom, so toggling between them made an animating tile (e.g. the
            // construction yard's corner) jitter by a pixel frame-to-frame.
            guard let texture = tileTexture(frame.tiles[i], palette: palette) else { continue }
            let node = overlayNodes[i] ?? makeCellNode(i)
            node.texture = texture
            overlayNodes[i] = node
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

    private func tileTexture(_ tile: FrameInfo.Tile, palette: Palette) -> SKTexture? {
        let usesWind = tileUsesWind(tile.groundSpriteIndex)
        let key = TileKey(tileId: tile.groundSpriteIndex, overlayId: tile.overlaySpriteIndex,
                          houseID: tile.houseID, windColour: usesWind ? packedWindColour() : 0, fog: showFog)
        if let cached = tileCache[key] { return cached }
        // The cell pixels — ground + overlay (walls) or a black fog cell — exactly as the static buffer.
        guard let pixels = FrameComposer.cell(tile, veiledTileIndex: veiledTileIndex, showFog: showFog, source: source),
              let image = IndexedImage.cgImage(indices: pixels, width: tileSize, height: tileSize, palette: palette)
        else { return nil }
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
                            flipped: sprite.flipped, flippedV: sprite.flippedV)
        if let cached = spriteCache[key] { return cached }
        let remap: (UInt8) -> UInt8 = sprite.house.map { house in { HouseRemap.sprite($0, house: house) } }
            ?? { $0 }
        // Bake the mirror(s) into the pixels rather than relying on a node transform — pre-rendered, and
        // immune to any transform quirk. Air units use a vertical mirror for their southern facings.
        let pixels = Self.mirror(sprite.frame.pixels, width: sprite.frame.width, height: sprite.frame.height,
                                 horizontal: sprite.flipped, vertical: sprite.flippedV)
        guard let image = IndexedImage.cgImage(indices: pixels, width: sprite.frame.width,
                                               height: sprite.frame.height, palette: palette,
                                               transparentIndex: 0, remap: remap) else { return nil }
        let texture = nearest(image)
        spriteCache[key] = texture
        return texture
    }

    /// A row-major indexed buffer mirrored horizontally (each row reversed) and/or vertically (row order
    /// reversed). `horizontal` is the W-half/RTL flip; `vertical` is the air units' southern-facing flip.
    nonisolated static func mirror(_ pixels: [UInt8], width: Int, height: Int,
                                   horizontal: Bool, vertical: Bool) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height, horizontal || vertical else { return pixels }
        var out = pixels
        for y in 0 ..< height {
            let sy = vertical ? (height - 1 - y) : y
            for x in 0 ..< width {
                let sx = horizontal ? (width - 1 - x) : x
                out[y * width + x] = pixels[sy * width + sx]
            }
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

    // MARK: - Sandworm shimmer

    /// Lay one displacement patch per sandworm: sample the static terrain under the worm's silhouette,
    /// displaced horizontally by the cycling blur offset (`ShimmerEffect`), and place it on the blur layer.
    private func updateBlurs(_ frame: FrameInfo, palette: Palette) {
        let side = tileSize * frame.mapWidth
        blurIndex = (blurIndex + 1) % ShimmerEffect.blurOffsets.count   // advance the heat-haze each frame
        let offset = ShimmerEffect.blurOffsets[blurIndex]
        var used = 0
        for blur in frame.blurs {
            guard let frameSprite = source.unitFrame(globalIndex: blur.sprite.spriteIndex) else { continue }
            let mask = Self.mirror(frameSprite.pixels, width: frameSprite.width, height: frameSprite.height,
                                   horizontal: blur.sprite.flipped, vertical: blur.sprite.flippedV)
            let cx = blur.positionX * tileSize / 256 + blur.sprite.offsetX
            let cy = blur.positionY * tileSize / 256 + blur.sprite.offsetY
            let left = cx - frameSprite.width / 2, top = cy - frameSprite.height / 2   // DRAWSPRITE_FLAG_CENTER
            guard let patch = ShimmerEffect.patch(
                terrain: terrainIndices, terrainWidth: side, terrainHeight: side,
                left: left, top: top, mask: mask, wormWidth: frameSprite.width, wormHeight: frameSprite.height,
                offset: offset, palette: palette) else { continue }
            let node = pooledBlur(used); used += 1
            node.texture = nearest(patch)
            node.size = CGSize(width: frameSprite.width, height: frameSprite.height)
            node.position = CGPoint(x: CGFloat(cx), y: CGFloat(side - cy))
            node.isHidden = false
        }
        for i in used ..< blurPool.count { blurPool[i].isHidden = true }
    }

    private func pooledBlur(_ i: Int) -> SKSpriteNode {
        if i < blurPool.count { return blurPool[i] }
        let node = SKSpriteNode()
        blurPool.append(node)
        blurLayer.addChild(node)
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
