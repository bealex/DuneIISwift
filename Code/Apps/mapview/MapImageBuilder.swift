import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIIWorld
import Foundation

/// Builds drawable images from a `GameState`: the terrain+structures tile layer (one composited
/// image) and per-unit sprite images. App-local (the real renderer will consume `FrameInfo`); here we
/// read the `GameState` directly since this is a verification tool.
@MainActor
enum MapImageBuilder {
    static let tilePx = 16
    static let mapTiles = 64
    static var sidePx: Int { tilePx * mapTiles }   // 1024

    struct UnitSprite { let image: CGImage; let centerX: Int; let centerY: Int }   // image-space (y down)

    /// The 1024×1024 terrain layer with structures stamped on top (both are `ICON.ICN` tiles).
    static func terrainImage(_ state: GameState, _ assets: AssetStore) -> CGImage? {
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

        for ty in 0 ..< mapTiles {
            for tx in 0 ..< mapTiles {
                stamp(tileID: Int(state.map[ty * mapTiles + tx].groundTileID), tileX: tx, tileY: ty)
            }
        }

        if let iconMap = assets.iconMap {
            for s in state.structures where s.o.flags.contains(.used) {
                guard let type = StructureType(rawValue: Int(s.o.type)) else { continue }
                let group = Int(StructureInfo[type].iconGroup)
                guard let tileIDs = iconMap.group(group)?.tileIDs, !tileIDs.isEmpty else { continue }
                let (w, h) = StructureCatalog.layout(iconGroup: group) ?? (1, 1)
                let states = max(1, tileIDs.count / (w * h))
                let base = min(2, states - 1) * w * h    // built state ≈ index 2
                let originX = Int(s.o.position.posX), originY = Int(s.o.position.posY)
                for r in 0 ..< h {
                    for c in 0 ..< w {
                        let idx = base + r * w + c
                        if idx < tileIDs.count { stamp(tileID: tileIDs[idx], tileX: originX + c, tileY: originY + r) }
                    }
                }
            }
        }

        return IndexedImage.cgImage(indices: buffer, width: side, height: side, palette: assets.palette)
    }

    /// One sprite per placed unit (north/base frame), house-recoloured, with its image-space centre.
    static func unitSprites(_ state: GameState, _ assets: AssetStore) -> [UnitSprite] {
        var result: [UnitSprite] = []
        for u in state.units where u.o.flags.contains(.used) {
            guard let type = UnitType(rawValue: Int(u.o.type)),
                  let group = bodyGroup(forUnitName: UnitInfo[type].o.name),
                  let frames = assets.shp(group.shp),
                  group.firstFrame < frames.frames.count else { continue }

            let frame = frames.frames[group.firstFrame]
            let house = House(rawValue: Int(u.o.houseID)) ?? .harkonnen
            guard let image = IndexedImage.cgImage(
                indices: frame.pixels, width: frame.width, height: frame.height,
                palette: assets.palette, transparentIndex: 0,
                remap: { HouseRemap.sprite($0, house: house) }) else { continue }

            let cx = Int(u.o.position.x) * tilePx / 256
            let cy = Int(u.o.position.y) * tilePx / 256
            result.append(UnitSprite(image: image, centerX: cx, centerY: cy))
        }
        return result
    }

    /// Resolve a unit's body sprite group, with aliases for names that differ from `SpriteCatalog`.
    private static func bodyGroup(forUnitName name: String) -> SpriteCatalog.Group? {
        let alias: [String: String] = [
            "Tank": "Combat Tank", "'Thopter": "Ornithopter",
            "Launcher": "Combat Tank", "Deviator": "Combat Tank", "Sonic Tank": "Combat Tank",
        ]
        let wanted = alias[name] ?? name
        return SpriteCatalog.unitGroups.first {
            $0.part == "body" && $0.unit.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }
}
