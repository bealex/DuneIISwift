import DuneIIFormats
import DuneIIRenderer

/// Adapts the `@MainActor` `AssetStore` to the renderer's value-type `DecodedSpriteSource` (ICON.ICN tiles
/// + the UNITS SHP sheets via the canonical `GlobalSprite` mapping).
enum SpriteSource {
    @MainActor
    static func make(assets: AssetStore) -> DecodedSpriteSource {
        var sheets: [String: Shp.FrameSet] = [:]
        for sheet in UnitSpriteSheet.allCases where sheets[sheet.fileName] == nil {
            if let set = assets.shp(sheet.fileName) { sheets[sheet.fileName] = set }
        }
        return DecodedSpriteSource(tileSet: assets.tileSet, sheets: sheets)
    }
}
