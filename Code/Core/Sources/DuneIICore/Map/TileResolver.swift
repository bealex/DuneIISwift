import Foundation

/// Pre-computes the four "magic" tile IDs OpenDUNE derives from
/// `ICON.MAP` at load time, and provides the `landscapeType` classifier
/// used throughout the simulation.
public struct TileResolver: Sendable {
    public let landscapeTileID: UInt16
    public let bloomTileID: UInt16
    public let builtSlabTileID: UInt16
    public let wallTileID: UInt16
    /// The raw icon map; kept so callers can look up other groups
    /// (craters, tracks, fog) lazily.
    public let iconMap: Formats.IconMap

    public init(iconMap: Formats.IconMap) {
        self.iconMap = iconMap
        self.landscapeTileID = iconMap.tileId(in: .landscape, offset: 0)
        self.bloomTileID = iconMap.tileId(in: .spiceBloom, offset: 0)
        self.builtSlabTileID = iconMap.tileId(in: .concreteSlab, offset: 2)
        self.wallTileID = iconMap.tileId(in: .walls, offset: 0)
    }

    /// Direct port of OpenDUNE's `Map_GetLandscapeType`.
    public func landscapeType(
        groundTileID: UInt16,
        overlayTileID: UInt16,
        hasStructure: Bool
    ) -> LandscapeType {
        if groundTileID == builtSlabTileID { return .concreteSlab }
        if groundTileID == bloomTileID || groundTileID == bloomTileID &+ 1 {
            return .bloomField
        }
        if groundTileID > wallTileID && groundTileID < wallTileID &+ 75 {
            return .wall
        }
        if overlayTileID == wallTileID { return .destroyedWall }
        if hasStructure { return .structure }

        let spriteOffset = Int(groundTileID) - Int(landscapeTileID)
        guard spriteOffset >= 0, spriteOffset < LandscapeLookup.spriteToLandscape.count else {
            return .entirelyRock
        }
        return LandscapeLookup.spriteToLandscape[spriteOffset]
    }
}
