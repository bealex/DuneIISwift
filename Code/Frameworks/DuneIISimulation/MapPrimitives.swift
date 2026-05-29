import DuneIIContracts
import DuneIIWorld

/// The replaceable seam for the native map primitives ported from OpenDUNE `src/map.c`. Injected into
/// `Simulation` so the implementation can be swapped (see `UnitPrimitives`).
///
/// Only the position-validity check is here so far; the landscape/spice/fog primitives
/// (`Map_GetLandscapeType`, `Map_ChangeSpiceAmount`, `Map_UnveilTile`, …) are blocked on the
/// sprite/scenario init that derives the runtime tile-id bases from `ICON.MAP` (`Sprites_Init`,
/// `sprites.c:274`) — see `Documentation/Plan.v1.md` §9.
public protocol MapPrimitives: Sendable {
    /// `Map_IsValidPosition` (`map.c`): is `position` (a packed tile) inside the playable bounds for
    /// `mapScale`? (Out-of-map bits, then the per-scale `MapInfo` rectangle.)
    func isValidPosition(_ position: UInt16, mapScale: UInt8) -> Bool

    /// `Map_GetLandscapeType` (`map.c`): classify a tile from its ground/overlay ids + the runtime
    /// tile-id bases. The structure case is just the tile's `hasStructure` flag.
    func landscapeType(_ tile: MapTile, tileIDs: TileIDs) -> LandscapeType
}

public struct DefaultMapPrimitives: MapPrimitives {
    public init() {}

    public func isValidPosition(_ position: UInt16, mapScale: UInt8) -> Bool {
        if position & 0xC000 != 0 { return false }
        let x = UInt16(Tile32.packedX(position))
        let y = UInt16(Tile32.packedY(position))
        let info = MapInfo.scales[Int(mapScale)]
        return info.minX <= x && x < info.minX + info.sizeX
            && info.minY <= y && y < info.minY + info.sizeY
    }

    public func landscapeType(_ tile: MapTile, tileIDs: TileIDs) -> LandscapeType {
        let ground = tile.groundTileID
        if ground == tileIDs.builtSlab { return .concreteSlab }
        if ground == tileIDs.bloom || ground == tileIDs.bloom + 1 { return .bloomField }
        if ground > tileIDs.wall && ground < tileIDs.wall + 75 { return .wall }
        if UInt16(tile.overlayTileID) == tileIDs.wall { return .destroyedWall }
        if tile.hasStructure { return .structure }
        let offset = Int(ground) - Int(tileIDs.landscape)
        if offset < 0 || offset > 80 { return .entirelyRock }
        return LandscapeType(rawValue: Int(DefaultMapPrimitives.landscapeSpriteMap[offset])) ?? .entirelyRock
    }

    /// `_landscapeSpriteMap[81]` (`map.c:523`): landscape sprite offset (0…80, from `g_landscapeTileID`)
    /// → `LandscapeType` raw value.
    static let landscapeSpriteMap: [UInt8] = [
        0, 1, 1, 1, 5, 1, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 4, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 2, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 6, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 9, 9, 9, 9, 9,
        9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9,
    ]
}
