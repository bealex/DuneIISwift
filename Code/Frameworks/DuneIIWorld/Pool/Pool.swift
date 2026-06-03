/// Pool sizing + sentinel constants, ported from OpenDUNE's `src/pool/*.h`. The pools are fixed-size
/// arrays; these are their bounds and the "invalid" sentinels.
public enum Pool {
    public static let unitIndexMax = 102  // UNIT_INDEX_MAX
    public static let unitIndexInvalid: UInt16 = 0xFFFF

    public static let structureIndexMaxSoft = 79  // highest index for a normal structure
    public static let structureIndexMaxHard = 82  // highest index for any structure (incl. specials)
    public static let structureIndexWall: UInt16 = 79
    public static let structureIndexSlab2x2: UInt16 = 80
    public static let structureIndexSlab1x1: UInt16 = 81
    public static let structureIndexInvalid: UInt16 = 0xFFFF

    public static let houseIndexMax = 6  // HOUSE_INDEX_MAX

    public static let teamIndexMax = 16  // TEAM_INDEX_MAX
    public static let teamIndexInvalid: UInt16 = 0xFFFF

    /// `HOUSE_INVALID` — the "any house" / "no house" sentinel for `PoolFind.houseID`.
    public static let houseInvalid: UInt8 = 0xFF
}

/// Search cursor + filter for the pool `find` iterators. A port of OpenDUNE's `PoolFindStruct`
/// (`src/pool/pool.h`); the result index is written back into `index` so a follow-up call resumes.
public struct PoolFind: Sendable, Equatable {
    public var houseID: UInt8  // house to match, or Pool.houseInvalid for any
    public var type: UInt16  // type to match, or 0xFFFF for any
    public var index: UInt16  // last visited find-array slot, or 0xFFFF to start from the beginning

    public init(houseID: UInt8 = Pool.houseInvalid, type: UInt16 = 0xFFFF, index: UInt16 = 0xFFFF) {
        self.houseID = houseID
        self.type = type
        self.index = index
    }
}
