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

    struct UnitSprite { let image: CGImage; let centerX: Int; let centerY: Int; let z: CGFloat }   // image-space (y down)

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

        return buffer
    }

    /// Colorize a `sidePx`×`sidePx` terrain index buffer through `palette`.
    static func colorize(_ buffer: [UInt8], palette: Palette) -> CGImage? {
        IndexedImage.cgImage(indices: buffer, width: sidePx, height: sidePx, palette: palette)
    }

    /// Sprites per placed unit (north/base frame, house-recoloured): the body, plus a separate turret
    /// sprite (above the body) for units with `hasTurret` — tanks/siege tanks (viewport.c draws both).
    static func unitSprites(_ state: GameState, _ assets: AssetStore) -> [UnitSprite] {
        var result: [UnitSprite] = []
        for u in state.units where u.o.flags.contains(.used) {
            guard let type = UnitType(rawValue: Int(u.o.type)) else { continue }
            let info = UnitInfo[type]
            // Sandworm / sonic blast are drawn with a sand-distortion BLUR (viewport.c), not a normal
            // palette sprite. Until that blur draw is ported, skip them rather than show a wrong blob.
            if info.o.flags.contains(.blurTile) { continue }

            let house = DuneIIRenderer.House(rawValue: Int(u.o.houseID)) ?? .harkonnen
            let cx = Int(u.o.position.x) * tilePx / 256
            let cy = Int(u.o.position.y) * tilePx / 256

            if let group = bodyGroup(forUnitName: info.o.name), let image = sprite(group, assets, house) {
                result.append(UnitSprite(image: image, centerX: cx, centerY: cy, z: 1))
            }
            if info.o.flags.contains(.hasTurret),
               let group = turretGroup(forUnitName: info.o.name), let image = sprite(group, assets, house) {
                result.append(UnitSprite(image: image, centerX: cx, centerY: cy, z: 2))
            }
        }
        return result
    }

    /// The north/base frame of a sprite group, house-recoloured (index 0 transparent).
    private static func sprite(_ group: SpriteCatalog.Group, _ assets: AssetStore, _ house: DuneIIRenderer.House) -> CGImage? {
        guard let frames = assets.shp(group.shp), group.firstFrame < frames.frames.count else { return nil }
        let frame = frames.frames[group.firstFrame]
        return IndexedImage.cgImage(
            indices: frame.pixels, width: frame.width, height: frame.height,
            palette: assets.palette, transparentIndex: 0,
            remap: { HouseRemap.sprite($0, house: house) })
    }

    private static func bodyGroup(forUnitName name: String) -> SpriteCatalog.Group? {
        group(forUnitName: name, part: "body")
    }

    private static func turretGroup(forUnitName name: String) -> SpriteCatalog.Group? {
        group(forUnitName: name, part: "turret")
    }

    /// Resolve a unit's sprite group, with aliases for names that differ from `SpriteCatalog`.
    private static func group(forUnitName name: String, part: String) -> SpriteCatalog.Group? {
        let alias: [String: String] = [
            "Tank": "Combat Tank", "'Thopter": "Ornithopter",
            "Launcher": "Combat Tank", "Deviator": "Combat Tank", "Sonic Tank": "Combat Tank",
        ]
        let wanted = alias[name] ?? name
        return SpriteCatalog.unitGroups.first {
            $0.part == part && $0.unit.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }
}
