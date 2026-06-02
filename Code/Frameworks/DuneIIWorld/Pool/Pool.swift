import Foundation

/// Pool sizing + sentinel constants, ported from OpenDUNE's `src/pool/*.h`. The pools are fixed-size
/// arrays; these are their bounds and the "invalid" sentinels.
public enum Pool {
    /// `UNIT_INDEX_MAX`. Faithful default 102. **Benchmark-only escape hatch:** the `DUNEII_UNIT_POOL`
    /// environment variable raises the cap so the parallelization benchmark can stress the unit phase with
    /// far more than the faithful 102 units (units are what the tick parallelizes; structures stay capped).
    /// Unset ⇒ 102, so every test/golden run is byte-identical to before. Clamped below `0x4000` because the
    /// unit-index encoding is `index | 0x4000` (`GameState+Index.swift:26`). It is a *constant per process*
    /// (read once at static init), so it introduces no mutable global state and stays deterministic.
    public static let unitIndexMax: Int = {
        guard let raw = ProcessInfo.processInfo.environment["DUNEII_UNIT_POOL"],
              let n = Int(raw), n > 0 else { return 102 }
        return min(n, 0x3FFF)
    }()
    public static let unitIndexInvalid: UInt16 = 0xFFFF

    public static let structureIndexMaxSoft = 79    // highest index for a normal structure
    public static let structureIndexMaxHard = 82    // highest index for any structure (incl. specials)
    public static let structureIndexWall: UInt16 = 79
    public static let structureIndexSlab2x2: UInt16 = 80
    public static let structureIndexSlab1x1: UInt16 = 81
    public static let structureIndexInvalid: UInt16 = 0xFFFF

    public static let houseIndexMax = 6             // HOUSE_INDEX_MAX

    public static let teamIndexMax = 16             // TEAM_INDEX_MAX
    public static let teamIndexInvalid: UInt16 = 0xFFFF

    /// `HOUSE_INVALID` — the "any house" / "no house" sentinel for `PoolFind.houseID`.
    public static let houseInvalid: UInt8 = 0xFF
}

/// Search cursor + filter for the pool `find` iterators. A port of OpenDUNE's `PoolFindStruct`
/// (`src/pool/pool.h`); the result index is written back into `index` so a follow-up call resumes.
public struct PoolFind: Sendable, Equatable {
    public var houseID: UInt8    // house to match, or Pool.houseInvalid for any
    public var type: UInt16      // type to match, or 0xFFFF for any
    public var index: UInt16     // last visited find-array slot, or 0xFFFF to start from the beginning

    public init(houseID: UInt8 = Pool.houseInvalid, type: UInt16 = 0xFFFF, index: UInt16 = 0xFFFF) {
        self.houseID = houseID
        self.type = type
        self.index = index
    }
}
