import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIScenarios
import DuneIIWorld
import Foundation

/// Renders a `ScenarioWorld`'s 8×8 region: the terrain (+ any building, which lives in the map's ground
/// tiles) as one composited `ICON.ICN` layer, and per-unit SHP sprites. Coordinates are relative to the
/// region's top-left, so the image is `sidePx`×`sidePx` (128×128).
@MainActor
enum ScenarioImageBuilder {
    static let tilePx = 16
    static let size = ScenarioTerrain.size      // 8
    static var sidePx: Int { tilePx * size }     // 128

    struct UnitSprite { let image: CGImage; let centerX: Int; let centerY: Int; let z: CGFloat; let flipped: Bool }

    /// The 128×128 palette-indexed terrain buffer (ground tiles of the 8×8 region, incl. building tiles).
    static func terrainIndices(_ world: ScenarioWorld, _ assets: ScenarioAssets) -> [UInt8]? {
        guard let tiles = assets.tileSet else { return nil }
        let side = sidePx
        var buffer = [UInt8](repeating: 0, count: side * side)
        let terrain = world.terrain
        for ly in 0 ..< size {
            for lx in 0 ..< size {
                let tileID = Int(world.state.map[Int(terrain.mapPacked(lx: lx, ly: ly))].groundTileID)
                guard tileID >= 0, tileID < tiles.tileCount else { continue }
                let pixels = tiles.tile(tileID)
                let ox = lx * tilePx, oy = ly * tilePx
                for py in 0 ..< tilePx {
                    let row = (oy + py) * side + ox
                    for px in 0 ..< tilePx { buffer[row + px] = pixels[py * tilePx + px] }
                }
            }
        }
        return buffer
    }

    static func colorize(_ buffer: [UInt8], palette: Palette) -> CGImage? {
        IndexedImage.cgImage(indices: buffer, width: sidePx, height: sidePx, palette: palette)
    }

    /// One sprite per placed unit's body + turret, house-recoloured, at its region-local image centre.
    static func unitSprites(_ world: ScenarioWorld, _ assets: ScenarioAssets) -> [UnitSprite] {
        let originPxX = world.terrain.originX * tilePx
        let originPxY = world.terrain.originY * tilePx
        var result: [UnitSprite] = []
        for u in world.state.units where u.o.flags.contains(.used) {
            guard let type = UnitType(rawValue: Int(u.o.type)) else { continue }
            if UnitInfo[type].o.flags.contains(.blurTile) { continue }    // sandworm shimmer not drawn here
            guard let sprites = UnitSprites.info(for: u) else { continue }

            // Use the effective house (Unit_GetHouseID) so a deviated unit shows its captor's colours.
            let house = DuneIIRenderer.House(rawValue: Int(world.state.unitHouseID(u))) ?? .harkonnen
            let cx = Int(u.o.position.x) * tilePx / 256 - originPxX
            let cy = Int(u.o.position.y) * tilePx / 256 - originPxY

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

    private static func layerImage(_ layer: UnitSpriteLayer, _ assets: ScenarioAssets,
                                   _ house: DuneIIRenderer.House) -> CGImage? {
        guard let (shp, frame) = globalSprite(layer.spriteIndex),
              let frames = assets.shp(shp), frame >= 0, frame < frames.frames.count else { return nil }
        let f = frames.frames[frame]
        return IndexedImage.cgImage(
            indices: f.pixels, width: f.width, height: f.height,
            palette: assets.palette, transparentIndex: 0,
            remap: { HouseRemap.sprite($0, house: house) })
    }

    /// Map a global unit-sprite index to its SHP + local frame (load-order bases, per `Sprites_Init`).
    private static func globalSprite(_ index: Int) -> (shp: String, frame: Int)? {
        if index >= 238 { return ("UNITS.SHP", index - 238) }
        if index >= 151 { return ("UNITS1.SHP", index - 151) }
        if index >= 111 { return ("UNITS2.SHP", index - 111) }
        return nil
    }
}
