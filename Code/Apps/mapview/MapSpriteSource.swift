import DuneIIFormats
import DuneIIRenderer

/// The app-side `WorldSpriteSource` for the renderer: a value-type snapshot of the loaded assets the
/// `FrameComposer` needs — the `ICON.ICN` terrain tiles and the three concatenated UNITS SHP sheets,
/// addressed by the canonical `GlobalSprite` load-order mapping. Holds decoded value types (no live
/// reference to the `@MainActor` `AssetStore`), so compositing stays pure.
struct MapSpriteSource: WorldSpriteSource {
    private let tileSet: Icn.TileSet?
    private let sheets: [String: Shp.FrameSet]

    @MainActor
    init(assets: AssetStore) {
        tileSet = assets.tileSet
        var sheets: [String: Shp.FrameSet] = [:]
        for sheet in UnitSpriteSheet.allCases where sheets[sheet.fileName] == nil {
            if let set = assets.shp(sheet.fileName) { sheets[sheet.fileName] = set }
        }
        self.sheets = sheets
    }

    var terrainTileSize: Int { tileSet?.tileWidth ?? 16 }

    func terrainTile(_ id: Int) -> [UInt8]? {
        guard let tileSet, id >= 0, id < tileSet.tileCount else { return nil }
        return tileSet.tile(id)
    }

    func unitFrame(globalIndex: Int) -> SpriteFrame? {
        guard let (sheet, frame) = GlobalSprite.unit(globalIndex), let set = sheets[sheet.fileName],
              frame >= 0, frame < set.frames.count else { return nil }
        let f = set.frames[frame]
        return SpriteFrame(width: f.width, height: f.height, pixels: f.pixels)
    }
}
