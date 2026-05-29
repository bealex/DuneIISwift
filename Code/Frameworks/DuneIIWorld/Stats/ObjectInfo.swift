/// The static stats common to a unit and a structure. A literal port of OpenDUNE's `ObjectInfo`
/// struct (`src/object.h`), embedded by both `UnitInfo` and `StructureInfo`.
///
/// Verified field-for-field against an OpenDUNE golden dump — see `Documentation/Algorithms/StatTables.md`.
public struct ObjectInfo: Sendable, Equatable {
    /// The 13-bit `ObjectInfo.flags` bitfield (`src/object.h`), bit positions in C declaration order.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let hasShadow           = Flags(rawValue: 1 << 0)  // has a shadow below it
        public static let factory             = Flags(rawValue: 1 << 1)  // can build other structures/units
        public static let notOnConcrete       = Flags(rawValue: 1 << 2)  // cannot be built on concrete
        public static let busyStateIsIncoming = Flags(rawValue: 1 << 3)  // BUSY lights mean a unit is incoming
        public static let blurTile            = Flags(rawValue: 1 << 4)  // blurs the tile the unit is on
        public static let hasTurret           = Flags(rawValue: 1 << 5)  // has a turret separate from the base
        public static let conquerable         = Flags(rawValue: 1 << 6)  // can be invaded + conquered when low
        public static let canBePickedUp       = Flags(rawValue: 1 << 7)  // can be picked up by a Carryall
        public static let noMessageOnDeath    = Flags(rawValue: 1 << 8)  // no message/sound when destroyed
        public static let tabSelectable       = Flags(rawValue: 1 << 9)  // selectable by pressing Tab
        public static let scriptNoSlowdown    = Flags(rawValue: 1 << 10) // off-viewport: don't slow scripting
        public static let targetAir           = Flags(rawValue: 1 << 11) // can target/shoot air units
        public static let priority            = Flags(rawValue: 1 << 12) // seen as a priority for auto-attack
    }

    public let stringIDAbbrev: UInt16       // StringID of the abbreviated name
    public let name: String
    public let stringIDFull: UInt16         // StringID of the full name
    public let wsa: String?                 // .wsa filename, or nil if none
    public let flags: Flags
    public let spawnChance: UInt16          // chance of spawning a unit (structure: on destruction)
    public let hitpoints: UInt16            // default hitpoints
    public let fogUncoverRadius: UInt16
    public let spriteID: UInt16
    public let buildCredits: UInt16         // cost to build; upgrading is 50% of this
    public let buildTime: UInt16
    public let availableCampaign: UInt16    // campaign (from 1) in which this becomes available
    public let structuresRequired: UInt32   // FLAG_STRUCTURE_* bitmask; 0xFFFFFFFF = FLAG_STRUCTURE_NEVER
    public let sortPriority: UInt8
    public let upgradeLevelRequired: UInt8
    public let actionsPlayer: [ActionType]  // 4 actions available to a player object
    public let available: Int8              // ordered/available: 1+ = yes, 0 = no, -1 = upgrade-first
    public let hintStringID: UInt16
    public let priorityBuild: UInt16        // build priority when picking what to build next
    public let priorityTarget: UInt16       // target priority when being targeted
    public let availableHouse: UInt8        // FLAG_HOUSE_* bitmask of houses this is available to
}

/// Compact positional constructor for the embedded `ObjectInfo` in the `UnitInfo` / `StructureInfo`
/// tables — keeps each table entry to one readable block. Module-internal; used only by the tables.
func makeObjectInfo(
    _ stringIDAbbrev: UInt16, _ name: String, _ stringIDFull: UInt16, _ wsa: String?,
    _ flags: ObjectInfo.Flags,
    spawnChance: UInt16, hitpoints: UInt16, fogUncoverRadius: UInt16, spriteID: UInt16,
    buildCredits: UInt16, buildTime: UInt16, availableCampaign: UInt16,
    structuresRequired: UInt32, sortPriority: UInt8, upgradeLevelRequired: UInt8,
    actionsPlayer: [ActionType], available: Int8, hintStringID: UInt16,
    priorityBuild: UInt16, priorityTarget: UInt16, availableHouse: UInt8
) -> ObjectInfo {
    ObjectInfo(
        stringIDAbbrev: stringIDAbbrev, name: name, stringIDFull: stringIDFull, wsa: wsa,
        flags: flags, spawnChance: spawnChance, hitpoints: hitpoints,
        fogUncoverRadius: fogUncoverRadius, spriteID: spriteID, buildCredits: buildCredits,
        buildTime: buildTime, availableCampaign: availableCampaign,
        structuresRequired: structuresRequired, sortPriority: sortPriority,
        upgradeLevelRequired: upgradeLevelRequired, actionsPlayer: actionsPlayer,
        available: available, hintStringID: hintStringID, priorityBuild: priorityBuild,
        priorityTarget: priorityTarget, availableHouse: availableHouse)
}
