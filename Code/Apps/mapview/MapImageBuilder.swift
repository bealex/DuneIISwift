import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation

/// Builds drawable images from a `GameState`: the terrain+structures tile layer (one composited
/// image) and per-unit sprite images. App-local (the real renderer will consume `FrameInfo`); here we
/// read the `GameState` directly since this is a verification tool. The unit sprite indices come from
/// the shared `UnitSprites` resolver (the `viewport.c` rules); this only maps a global index to an SHP
/// frame and colorizes.
@MainActor
enum MapImageBuilder {
    static let tilePx = 16
    static let mapTiles = 64
    static var sidePx: Int { tilePx * mapTiles }   // 1024

    struct UnitSprite { let image: CGImage; let centerX: Int; let centerY: Int; let z: CGFloat; let flipped: Bool }   // image-space (y down)

    /// The 1024×1024 palette-indexed terrain buffer with structures stamped on top (both are
    /// `ICON.ICN` tiles). Built once per load; the game loop re-colorizes it each tick (so the
    /// palette-cycled indices — e.g. the windtrap light, index 223 — animate) via `colorize`.
    static func terrainIndices(_ state: GameState, _ assets: AssetStore) -> [UInt8]? {
        guard let tiles = assets.tileSet else { return nil }
        let side = sidePx
        var buffer = [UInt8](repeating: 0, count: side * side)

        func stamp(tileID: Int, tileX: Int, tileY: Int) {
            guard tileID >= 0, tileID < tiles.tileCount, tileX >= 0, tileY >= 0,
                  tileX < mapTiles, tileY < mapTiles else { return }
            let pixels = tiles.tile(tileID)
            let ox = tileX * tilePx, oy = tileY * tilePx
            for py in 0 ..< tilePx {
                let row = (oy + py) * side + ox
                for px in 0 ..< tilePx { buffer[row + px] = pixels[py * tilePx + px] }
            }
        }

        // Structures are stamped into the map's ground tiles by the engine (Structure_UpdateMap +
        // the animation system), so a single pass over g_map draws terrain and (animating) buildings.
        for ty in 0 ..< mapTiles {
            for tx in 0 ..< mapTiles {
                stamp(tileID: Int(state.map[ty * mapTiles + tx].groundTileID), tileX: tx, tileY: ty)
            }
        }

        applySandwormBlur(&buffer, state, assets)
        return buffer
    }

    /// `DRAWSPRITE_FLAG_BLUR` (`gui.c`): where a `blurTile` unit's sprite is set, the underlying pixel
    /// is replaced by the one `blurOffset` to the right — a sand shimmer. Sandworms are static in the
    /// viewer, so bake the displacement into the terrain buffer at the worm's shape.
    private static func applySandwormBlur(_ buffer: inout [UInt8], _ state: GameState, _ assets: AssetStore) {
        let side = sidePx
        let blurOffset = 2   // one of gui.c's blurOffsets[]; static here (the shimmer would cycle these)
        let original = buffer
        for u in state.units where u.o.flags.contains(.used) {
            guard let type = UnitType(rawValue: Int(u.o.type)), UnitInfo[type].o.flags.contains(.blurTile),
                  let (shp, frameIndex) = globalSprite(Int(UnitInfo[type].groundSpriteID)),
                  let frames = assets.shp(shp), frameIndex < frames.frames.count else { continue }
            let frame = frames.frames[frameIndex]
            let ox = Int(u.o.position.x) * tilePx / 256 - frame.width / 2
            let oy = Int(u.o.position.y) * tilePx / 256 - frame.height / 2
            for sy in 0 ..< frame.height {
                for sx in 0 ..< frame.width where frame.pixels[sy * frame.width + sx] != 0 {
                    let bx = ox + sx, by = oy + sy
                    guard bx >= 0, by >= 0, bx < side, by < side else { continue }
                    let p = by * side + bx
                    if p + blurOffset < original.count { buffer[p] = original[p + blurOffset] }
                }
            }
        }
    }

    /// Colorize a `sidePx`×`sidePx` terrain index buffer through `palette`.
    static func colorize(_ buffer: [UInt8], palette: Palette) -> CGImage? {
        IndexedImage.cgImage(indices: buffer, width: sidePx, height: sidePx, palette: palette)
    }

    /// One sprite per placed unit's body + turret (from `UnitSprites`), house-recoloured, at its
    /// image-space centre. Sandworm/sonic-blast (`blurTile`) are drawn as the terrain distortion above.
    static func unitSprites(_ state: GameState, _ assets: AssetStore) -> [UnitSprite] {
        var result: [UnitSprite] = []
        for u in state.units where u.o.flags.contains(.used) {
            guard let type = UnitType(rawValue: Int(u.o.type)) else { continue }
            if UnitInfo[type].o.flags.contains(.blurTile) { continue }
            guard let sprites = UnitSprites.info(for: u) else { continue }

            let house = DuneIIRenderer.House(rawValue: Int(u.o.houseID)) ?? .harkonnen
            let cx = Int(u.o.position.x) * tilePx / 256
            let cy = Int(u.o.position.y) * tilePx / 256

            if let image = layerImage(sprites.body, assets, house) {
                result.append(UnitSprite(image: image, centerX: cx, centerY: cy, z: 1, flipped: sprites.body.flipped))
            }
            if let turret = sprites.turret, let image = layerImage(turret, assets, house) {
                result.append(UnitSprite(image: image, centerX: cx + turret.offsetX, centerY: cy + turret.offsetY,
                                         z: 2, flipped: turret.flipped))
            }
        }
        return result
    }

    private static func layerImage(_ layer: UnitSpriteLayer, _ assets: AssetStore, _ house: DuneIIRenderer.House) -> CGImage? {
        guard let (shp, frame) = globalSprite(layer.spriteIndex) else { return nil }
        return spriteFrame(shp: shp, frame: frame, assets, house)
    }

    /// Map a global unit-sprite index to its SHP + local frame, via the `Sprites_Init` load-order
    /// bases (UNITS2 = 111, UNITS1 = 151, UNITS = 238).
    private static func globalSprite(_ index: Int) -> (shp: String, frame: Int)? {
        if index >= 238 { return ("UNITS.SHP", index - 238) }
        if index >= 151 { return ("UNITS1.SHP", index - 151) }
        if index >= 111 { return ("UNITS2.SHP", index - 111) }
        return nil
    }

    /// A specific (SHP-local) frame, house-recoloured (index 0 transparent).
    private static func spriteFrame(shp: String, frame: Int, _ assets: AssetStore, _ house: DuneIIRenderer.House) -> CGImage? {
        guard let frames = assets.shp(shp), frame >= 0, frame < frames.frames.count else { return nil }
        let f = frames.frames[frame]
        return IndexedImage.cgImage(
            indices: f.pixels, width: f.width, height: f.height,
            palette: assets.palette, transparentIndex: 0,
            remap: { HouseRemap.sprite($0, house: house) })
    }
}
