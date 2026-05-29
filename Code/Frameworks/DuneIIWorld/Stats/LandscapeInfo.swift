/// The kinds of map tile, in OpenDUNE's `LandscapeType` order (`src/map.h:7`).
public enum LandscapeType: Int, CaseIterable, Sendable {
    case normalSand = 0
    case partialRock = 1
    case entirelyDune = 2
    case partialDune = 3
    case entirelyRock = 4
    case mostlyRock = 5
    case entirelyMountain = 6
    case partialMountain = 7
    case spice = 8
    case thickSpice = 9
    case concreteSlab = 10
    case wall = 11
    case structure = 12
    case destroyedWall = 13
    case bloomField = 14
}

/// How a unit traverses terrain, in OpenDUNE's `MovementType` order (`src/unit.h:106`). Indexes
/// `LandscapeInfo.movementSpeed`.
public enum MovementType: Int, CaseIterable, Sendable {
    case foot = 0
    case tracked = 1
    case harvester = 2
    case wheeled = 3
    case winger = 4
    case slither = 5
}

/// Per-landscape static stats. A literal port of OpenDUNE's `LandscapeInfo` struct (`src/map.h`) and
/// `g_table_landscapeInfo[]` (`src/table/landscapeinfo.c`). Keyed by `LandscapeType`.
///
/// Verified field-for-field against an OpenDUNE golden dump — see `Documentation/Algorithms/StatTables.md`.
public struct LandscapeInfo: Sendable, Equatable {
    /// Movement speed per `MovementType` (6 entries) on this terrain.
    public let movementSpeed: [UInt8]
    public let letUnitWobble: Bool          // unit wobbles while moving on this tile
    public let isValidForStructure: Bool    // buildable by a structure with notOnConcrete == false
    public let isSand: Bool                 // sand/dune/spice/bloom
    public let isValidForStructure2: Bool   // buildable by a structure with notOnConcrete == true
    public let canBecomeSpice: Bool
    public let craterType: UInt8            // 0 none, 1 sand, 2 concrete
    public let radarColour: UInt16
    public let spriteID: UInt16

    /// Speed for `movement` on this terrain.
    public func speed(_ movement: MovementType) -> UInt8 { movementSpeed[movement.rawValue] }

    /// Stats for `landscape`.
    public static subscript(_ landscape: LandscapeType) -> LandscapeInfo { table[landscape.rawValue] }

    /// `g_table_landscapeInfo[]`, indexed by `LandscapeType.rawValue`.
    public static let table: [LandscapeInfo] = [
        entry([112, 112, 112, 160, 255, 192], false, false, true, false, true, 1, 88, 37),     // 0 normalSand
        entry([160, 112, 112, 64, 255, 0], true, false, false, false, false, 1, 28, 39),       // 1 partialRock
        entry([112, 160, 160, 160, 255, 192], false, false, true, false, true, 1, 92, 41),     // 2 entirelyDune
        entry([112, 160, 160, 160, 255, 192], false, false, true, false, true, 1, 89, 43),     // 3 partialDune
        entry([112, 160, 160, 112, 255, 0], true, true, false, true, false, 2, 30, 45),        // 4 entirelyRock
        entry([160, 160, 160, 160, 255, 0], true, true, false, true, false, 2, 29, 47),        // 5 mostlyRock
        entry([64, 0, 0, 0, 255, 0], true, false, false, false, false, 0, 12, 49),             // 6 entirelyMountain
        entry([64, 0, 0, 0, 255, 0], true, false, false, false, false, 0, 133, 51),            // 7 partialMountain
        entry([112, 160, 160, 160, 255, 192], false, false, true, false, true, 1, 215, 53),    // 8 spice
        entry([112, 160, 160, 160, 255, 192], true, false, true, false, true, 1, 216, 53),     // 9 thickSpice
        entry([255, 255, 255, 255, 255, 0], false, true, false, false, false, 2, 133, 51),     // 10 concreteSlab
        entry([0, 0, 0, 0, 255, 0], false, false, false, false, false, 0, 65535, 31),          // 11 wall
        entry([0, 0, 0, 0, 255, 0], false, false, false, false, false, 0, 65535, 31),          // 12 structure
        entry([160, 160, 160, 160, 255, 0], true, true, false, true, false, 2, 29, 47),        // 13 destroyedWall
        entry([112, 112, 112, 160, 255, 192], false, false, true, false, true, 1, 50, 57),     // 14 bloomField
    ]

    private static func entry(
        _ movementSpeed: [UInt8], _ letUnitWobble: Bool, _ isValidForStructure: Bool, _ isSand: Bool,
        _ isValidForStructure2: Bool, _ canBecomeSpice: Bool, _ craterType: UInt8,
        _ radarColour: UInt16, _ spriteID: UInt16
    ) -> LandscapeInfo {
        LandscapeInfo(
            movementSpeed: movementSpeed, letUnitWobble: letUnitWobble,
            isValidForStructure: isValidForStructure, isSand: isSand,
            isValidForStructure2: isValidForStructure2, canBecomeSpice: canBecomeSpice,
            craterType: craterType, radarColour: radarColour, spriteID: spriteID
        )
    }
}
