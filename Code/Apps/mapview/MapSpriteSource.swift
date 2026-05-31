import DuneIIFormats
import DuneIIRenderer

/// The app-side adapter from `mapview`'s `@MainActor` `AssetStore` to the renderer's reusable, value-type
/// `DecodedSpriteSource` (the `ICON.ICN` terrain tiles + the concatenated UNITS SHP sheets, keyed by the
/// canonical `GlobalSprite` load-order mapping). The decode/lookup logic lives in `DecodedSpriteSource`.
enum MapSpriteSource {
    @MainActor
    static func make(assets: AssetStore) -> DecodedSpriteSource {
        var sheets: [String: Shp.FrameSet] = [:]
        for sheet in UnitSpriteSheet.allCases where sheets[sheet.fileName] == nil {
            if let set = assets.shp(sheet.fileName) { sheets[sheet.fileName] = set }
        }
        return DecodedSpriteSource(tileSet: assets.tileSet, sheets: sheets)
    }
}
