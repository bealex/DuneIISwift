/// One map cell. A port of OpenDUNE's `Tile` struct (`src/map.h`), a packed 32-bit bitfield
/// (`assert_compile(sizeof(Tile) == 0x04)`). Modelled with stored properties plus a `packed`
/// round-trip for save compatibility; the bit layout is the one documented in `map.h` and
/// golden-pinned against the oracle — see `Documentation/Architecture/DataModel.md`.
public struct MapTile: Sendable, Equatable {
    public var groundTileID: UInt16 = 0     // 9 bits: the icon drawn on this tile
    public var overlayTileID: UInt8 = 0     // 7 bits: overlay drawn over the tile
    public var houseID: UInt8 = 0           // 3 bits: owning house
    public var isUnveiled = false           // no fog
    public var hasUnit = false
    public var hasStructure = false
    public var hasAnimation = false
    public var hasExplosion = false
    public var index: UInt8 = 0             // 8 bits: structure/unit index (1 means object 0, etc.)

    public init() {}

    /// Unpack from the on-disk/in-engine 32-bit form (`map.h` bit layout).
    public init(packed: UInt32) {
        groundTileID  = UInt16(packed & 0x1FF)
        overlayTileID = UInt8((packed >> 9) & 0x7F)
        houseID       = UInt8((packed >> 16) & 0x7)
        isUnveiled    = (packed >> 19) & 1 != 0
        hasUnit       = (packed >> 20) & 1 != 0
        hasStructure  = (packed >> 21) & 1 != 0
        hasAnimation  = (packed >> 22) & 1 != 0
        hasExplosion  = (packed >> 23) & 1 != 0
        index         = UInt8((packed >> 24) & 0xFF)
    }

    /// Pack to the 32-bit form.
    public var packed: UInt32 {
        UInt32(groundTileID & 0x1FF)
            | (UInt32(overlayTileID & 0x7F) << 9)
            | (UInt32(houseID & 0x7) << 16)
            | (isUnveiled ? 1 << 19 : 0)
            | (hasUnit ? 1 << 20 : 0)
            | (hasStructure ? 1 << 21 : 0)
            | (hasAnimation ? 1 << 22 : 0)
            | (hasExplosion ? 1 << 23 : 0)
            | (UInt32(index) << 24)
    }
}

/// The map size for a given map scale. A port of OpenDUNE's `MapInfo` (`src/map.h`); the three
/// entries of `g_mapInfos`.
public struct MapInfo: Sendable, Equatable {
    public let minX: UInt16
    public let minY: UInt16
    public let sizeX: UInt16
    public let sizeY: UInt16

    public init(minX: UInt16, minY: UInt16, sizeX: UInt16, sizeY: UInt16) {
        self.minX = minX; self.minY = minY; self.sizeX = sizeX; self.sizeY = sizeY
    }

    /// `g_mapInfos[3]` (`map.c:57`): the playable bounds for each map scale (0 = 62×62, 1 = 32×32,
    /// 2 = 21×21). Indexed by `Scenario.mapScale`.
    public static let scales: [MapInfo] = [
        MapInfo(minX: 1, minY: 1, sizeX: 62, sizeY: 62),
        MapInfo(minX: 16, minY: 16, sizeX: 32, sizeY: 32),
        MapInfo(minX: 21, minY: 21, sizeX: 21, sizeY: 21),
    ]
}
