import DuneIIFormats

/// A value-type `WorldSpriteSource` over already-decoded assets — the `ICON.ICN` terrain `TileSet` and the
/// concatenated UNITS SHP sheets, addressed by the canonical `GlobalSprite` load-order mapping. Holds only
/// decoded value types (no live `@MainActor` asset store), so it is usable from a headless run, a test, or
/// an app. The app/test constructs it from whatever asset loader it has.
public struct DecodedSpriteSource: WorldSpriteSource {
    private let tileSet: Icn.TileSet?
    private let sheets: [String: Shp.FrameSet]

    /// - Parameters:
    ///   - tileSet: the decoded `ICON.ICN` tiles (the terrain layer), or `nil` for a sprite-only source.
    ///   - sheets: the decoded UNITS SHP frame sets keyed by file name (`UNITS.SHP`/`UNITS1.SHP`/`UNITS2.SHP`).
    public init(tileSet: Icn.TileSet?, sheets: [String: Shp.FrameSet]) {
        self.tileSet = tileSet
        self.sheets = sheets
    }

    public var terrainTileSize: Int { tileSet?.tileWidth ?? 16 }

    public func terrainTile(_ id: Int) -> [UInt8]? {
        guard let tileSet, id >= 0, id < tileSet.tileCount else { return nil }

        return tileSet.tile(id)
    }

    public func unitFrame(globalIndex: Int) -> SpriteFrame? {
        guard
            let (sheet, frame) = GlobalSprite.unit(globalIndex),
            let set = sheets[sheet.fileName],
            frame >= 0,
            frame < set.frames.count
        else { return nil }

        let f = set.frames[frame]
        return SpriteFrame(width: f.width, height: f.height, pixels: f.pixels)
    }
}
