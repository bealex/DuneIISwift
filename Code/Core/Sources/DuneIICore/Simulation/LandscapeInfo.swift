import Foundation

extension Simulation {
    /// Per-landscape-type stats, trimmed to the fields our pathfinder
    /// (`Unit_GetTileEnterScore`) + simple gameplay queries need. Source:
    /// `src/table/landscapeinfo.c`. The full OpenDUNE struct also carries
    /// `craterType` / `radarColour` / `spriteID` which we'll port when
    /// the renderer or radar needs them.
    public struct LandscapeInfo: Sendable, Equatable {
        /// `movementSpeed[MovementType]` — multiplier 0..255 scaling the
        /// unit's movingSpeedFactor when entering this tile. `0` = the
        /// unit can't enter. Index order matches `MovementType.rawValue`:
        /// foot, tracked, harvester, wheeled, winger, slither.
        public let movementSpeed: [UInt8]   // 6 entries
        public let letUnitWobble: Bool
        /// Used by non-CONSTRUCTION_YARD buildings: the tile must be
        /// rock or concrete. True for: ROCK (4), MOSTLY_ROCK (5),
        /// CONCRETE_SLAB (10), DESTROYED_WALL (13).
        public let isValidForStructure: Bool
        /// Used by CONSTRUCTION_YARD (the only structure with
        /// `notOnConcrete=true`): tile must be rock-family. Narrower
        /// than `isValidForStructure` — `CONCRETE_SLAB` is excluded,
        /// so a CY cannot sit on an existing slab. OpenDUNE quirk
        /// ported verbatim.
        public let isValidForStructure2: Bool
        public let isSand: Bool
        public let canBecomeSpice: Bool

        public static let table: [LandscapeInfo] = [
            // 0 LST_NORMAL_SAND
            LandscapeInfo(movementSpeed: [112, 112, 112, 160, 255, 192],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: true, canBecomeSpice: true),
            // 1 LST_PARTIAL_ROCK
            LandscapeInfo(movementSpeed: [160, 112, 112, 64,  255, 0],
                          letUnitWobble: true,  isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: false, canBecomeSpice: false),
            // 2 LST_ENTIRELY_DUNE
            LandscapeInfo(movementSpeed: [112, 160, 160, 160, 255, 192],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: true, canBecomeSpice: true),
            // 3 LST_PARTIAL_DUNE
            LandscapeInfo(movementSpeed: [112, 160, 160, 160, 255, 192],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: true, canBecomeSpice: true),
            // 4 LST_ENTIRELY_ROCK
            LandscapeInfo(movementSpeed: [112, 160, 160, 112, 255, 0],
                          letUnitWobble: true, isValidForStructure: true,
                          isValidForStructure2: true,
                          isSand: false, canBecomeSpice: false),
            // 5 LST_MOSTLY_ROCK — fixed from pre-4b (was isValidForStructure=false).
            LandscapeInfo(movementSpeed: [160, 160, 160, 160, 255, 0],
                          letUnitWobble: true, isValidForStructure: true,
                          isValidForStructure2: true,
                          isSand: false, canBecomeSpice: false),
            // 6 LST_ENTIRELY_MOUNTAIN
            LandscapeInfo(movementSpeed: [64, 0, 0, 0, 255, 0],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: false, canBecomeSpice: false),
            // 7 LST_PARTIAL_MOUNTAIN
            LandscapeInfo(movementSpeed: [64, 0, 0, 0, 255, 0],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: false, canBecomeSpice: false),
            // 8 LST_SPICE
            LandscapeInfo(movementSpeed: [112, 160, 160, 160, 255, 192],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: true, canBecomeSpice: true),
            // 9 LST_THICK_SPICE
            LandscapeInfo(movementSpeed: [112, 160, 160, 160, 255, 192],
                          letUnitWobble: true, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: true, canBecomeSpice: true),
            // 10 LST_CONCRETE_SLAB
            LandscapeInfo(movementSpeed: [255, 255, 255, 255, 255, 0],
                          letUnitWobble: false, isValidForStructure: true,
                          isValidForStructure2: false,
                          isSand: false, canBecomeSpice: false),
            // 11 LST_WALL
            LandscapeInfo(movementSpeed: [0, 0, 0, 0, 255, 0],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: false, canBecomeSpice: false),
            // 12 LST_STRUCTURE
            LandscapeInfo(movementSpeed: [0, 0, 0, 0, 255, 0],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: false, canBecomeSpice: false),
            // 13 LST_DESTROYED_WALL — fixed from pre-4b (was isValidForStructure=false).
            LandscapeInfo(movementSpeed: [160, 160, 160, 160, 255, 0],
                          letUnitWobble: true, isValidForStructure: true,
                          isValidForStructure2: true,
                          isSand: false, canBecomeSpice: false),
            // 14 LST_BLOOM_FIELD
            LandscapeInfo(movementSpeed: [112, 112, 112, 160, 255, 192],
                          letUnitWobble: false, isValidForStructure: false,
                          isValidForStructure2: false,
                          isSand: true, canBecomeSpice: true)
        ]

        public static func lookup(_ landscape: LandscapeType) -> LandscapeInfo {
            let i = landscape.rawValue
            if i >= 0, i < table.count { return table[i] }
            // Safety fallback — should never hit in practice.
            return table[0]
        }
    }
}
