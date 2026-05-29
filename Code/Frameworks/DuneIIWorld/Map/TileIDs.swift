import DuneIIFormats

/// The runtime tile-id bases derived from `ICON.MAP` at load — a port of the assignments in
/// OpenDUNE's `Sprites_Init` (`src/sprites.c:274`). They anchor `Map_GetLandscapeType` and friends
/// (a tile's `groundTileID` is classified by its offset from these bases). Each is the icon-group's
/// tile at a fixed offset, via the `IconMap` (`g_iconMap[g_iconMap[ICM_ICONGROUP_X] + offset]`).
public struct TileIDs: Sendable, Equatable {
    public var veiled: UInt16 = 0       // FOG_OF_WAR group, tile 16
    public var bloom: UInt16 = 0        // SPICE_BLOOM group, tile 0
    public var builtSlab: UInt16 = 0    // CONCRETE_SLAB group, tile 2
    public var landscape: UInt16 = 0    // LANDSCAPE group, tile 0
    public var wall: UInt16 = 0         // WALLS group, tile 0

    public init() {}

    /// Derive the bases from a decoded `ICON.MAP`. Returns `nil` if a required group/tile is missing.
    public init?(iconMap: IconMap) {
        // ICM_ICONGROUP_* indices (`sprites.h`): WALLS 6, FOG_OF_WAR 7, CONCRETE_SLAB 8, LANDSCAPE 9,
        // SPICE_BLOOM 10. Uses the flat lookup (the fog base reaches past its group, by design).
        guard let v = iconMap.tileID(group: 7, offset: 16),
              let b = iconMap.tileID(group: 10, offset: 0),
              let s = iconMap.tileID(group: 8, offset: 2),
              let l = iconMap.tileID(group: 9, offset: 0),
              let w = iconMap.tileID(group: 6, offset: 0)
        else { return nil }
        veiled = UInt16(v); bloom = UInt16(b); builtSlab = UInt16(s); landscape = UInt16(l); wall = UInt16(w)
    }
}
