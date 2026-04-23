import Foundation

// MARK: - House

public enum House: String, Sendable, CaseIterable {
    case atreides = "Atreides"
    case ordos = "Ordos"
    case harkonnen = "Harkonnen"
    case fremen = "Fremen"
    case sardaukar = "Sardaukar"
    case mercenary = "Mercenary"

    /// Case-insensitive parser matching OpenDUNE's `House_StringToType`.
    static func parse(_ s: String) -> House? {
        let lower = s.lowercased()
        return House.allCases.first(where: { $0.rawValue.lowercased() == lower })
    }

    /// OpenDUNE `HouseType` numeric ID (`HOUSE_*` in `src/house.h`).
    public var typeID: UInt8 {
        switch self {
        case .harkonnen: return 0
        case .atreides:  return 1
        case .ordos:     return 2
        case .fremen:    return 3
        case .sardaukar: return 4
        case .mercenary: return 5
        }
    }
}

public enum HouseBrain: String, Sendable {
    case human = "Human"
    case cpu = "CPU"

    static func parse(_ s: String) -> HouseBrain? {
        HouseBrain(rawValue: s) ?? HouseBrain(rawValue: s.capitalized)
    }
}

// MARK: - Unit & action types

/// Unit roster per OpenDUNE `src/table/unitinfo.c`. Names match the
/// strings shipped in the INIs.
public enum UnitType: String, Sendable, CaseIterable {
    case carryall = "Carryall"
    case ornithopter = "'Thopter"
    case infantry = "Infantry"
    case troopers = "Troopers"
    case soldier = "Soldier"
    case trooper = "Trooper"
    case saboteur = "Saboteur"
    case launcher = "Launcher"
    case deviator = "Deviator"
    case tank = "Tank"
    case siegeTank = "Siege Tank"
    case devastator = "Devastator"
    case sonicTank = "Sonic Tank"
    case trike = "Trike"
    case raider = "Raider Trike"
    case quad = "Quad"
    case harvester = "Harvester"
    case mcv = "MCV"
    case sandworm = "Sandworm"
    case frigate = "Frigate"

    static func parse(_ s: String) -> UnitType? {
        let lower = s.lowercased()
        return UnitType.allCases.first(where: { $0.rawValue.lowercased() == lower })
    }

    /// OpenDUNE `UnitType` numeric ID (`UNIT_*` in `src/unit.h`).
    public var typeID: UInt8 {
        switch self {
        case .carryall:    return 0
        case .ornithopter: return 1
        case .infantry:    return 2
        case .troopers:    return 3
        case .soldier:     return 4
        case .trooper:     return 5
        case .saboteur:    return 6
        case .launcher:    return 7
        case .deviator:    return 8
        case .tank:        return 9
        case .siegeTank:   return 10
        case .devastator:  return 11
        case .sonicTank:   return 12
        case .trike:       return 13
        case .raider:      return 14
        case .quad:        return 15
        case .harvester:   return 16
        case .mcv:         return 17
        case .sandworm:    return 25
        case .frigate:     return 26
        }
    }
}

public enum UnitAction: String, Sendable, CaseIterable {
    case attack = "Attack"
    case move = "Move"
    case retreat = "Retreat"
    case stop = "Stop"
    case ambush = "Ambush"
    case hunt = "Hunt"
    case guard_ = "Guard"   // `guard` is reserved in Swift
    case area = "Area Guard"
    case harvest = "Harvest"
    case returnAction = "Return"
    case die = "Die"

    static func parse(_ s: String) -> UnitAction? {
        let lower = s.lowercased()
        return UnitAction.allCases.first(where: { $0.rawValue.lowercased() == lower })
    }

    /// OpenDUNE `ActionType` numeric ID (`ACTION_*` in `src/unit.h:82`).
    /// Used to seed `UnitSlot.actionID` at scenario-load time so the EMC
    /// scheduler dispatches to the correct `UNIT.EMC` entry point
    /// (`ACTION_GUARD` for idle fidget, `ACTION_HUNT` for enemy AI, etc.).
    public var typeID: UInt8 {
        switch self {
        case .attack:       return 0
        case .move:         return 1
        case .retreat:      return 2
        case .guard_:       return 3
        case .area:         return 4
        case .harvest:      return 5
        case .returnAction: return 6
        case .stop:         return 7
        case .ambush:       return 8
        case .die:          return 10
        case .hunt:         return 11
        }
    }
}

// MARK: - Structure types

public enum StructureType: String, Sendable, CaseIterable {
    case slab1x1 = "Concrete Slab"
    case slab2x2 = "4 Slab"
    case palace = "Palace"
    case lightFactory = "Light Fctry"
    case heavyFactory = "Heavy Fctry"
    case hiTech = "Hi-Tech"
    case ixResearch = "IX"
    case worTrooper = "WOR"
    case constructionYard = "Const Yard"
    case barracks = "Barracks"
    case windtrap = "Windtrap"
    case starport = "Starport"
    case refinery = "Refinery"
    case repair = "Repair"
    case turret = "Turret"
    case rocketTurret = "R-Turret"
    case silo = "Silo"
    case outpost = "Outpost"
    case wall = "Wall"

    static func parse(_ s: String) -> StructureType? {
        let lower = s.lowercased()
        // Scenario INIs use alternate spellings for a few types. Accept
        // the variants observed across SCEN*.INI missions.
        switch lower {
        case "concrete":    return .slab1x1      // GEN rows write `Concrete`
        case "spice silo":  return .silo         // mission 2+ uses `Spice Silo`
        default: break
        }
        return StructureType.allCases.first(where: { $0.rawValue.lowercased() == lower })
    }

    /// OpenDUNE `StructureType` numeric ID (`STRUCTURE_*` in `src/structure.h`).
    public var typeID: UInt8 {
        switch self {
        case .slab1x1:          return 0
        case .slab2x2:          return 1
        case .palace:           return 2
        case .lightFactory:     return 3
        case .heavyFactory:     return 4
        case .hiTech:           return 5
        case .ixResearch:       return 6
        case .worTrooper:       return 7
        case .constructionYard: return 8
        case .windtrap:         return 9
        case .barracks:         return 10
        case .starport:         return 11
        case .refinery:         return 12
        case .repair:           return 13
        case .wall:             return 14
        case .turret:           return 15
        case .rocketTurret:     return 16
        case .silo:             return 17
        case .outpost:          return 18
        }
    }
}

// MARK: - Scenario

public struct Scenario: Sendable {
    public struct Briefing: Sendable {
        public var losePicture: String = ""
        public var winPicture: String = ""
        public var briefPicture: String = ""
        public var timeOut: Int = 0
        public var mapScale: Int = 1
        public var cursorPos: UInt16 = 0
        public var tacticalPos: UInt16 = 0
        public var loseFlags: Int = 0
        public var winFlags: Int = 0
    }

    public struct MapField: Sendable {
        public var initialSpiceFields: [UInt16] = []
        public var initialBlooms: [UInt16] = []
        public var initialSpecials: [UInt16] = []
        public var seed: UInt32 = 0
    }

    public struct HouseLayout: Sendable {
        public var quota: Int = 0
        public var credits: Int = 0
        public var brain: HouseBrain = .cpu
        public var maxUnits: Int = 0

        public init(quota: Int = 0, credits: Int = 0, brain: HouseBrain = .cpu, maxUnits: Int = 0) {
            self.quota = quota
            self.credits = credits
            self.brain = brain
            self.maxUnits = maxUnits
        }
    }

    public struct UnitSpawn: Sendable {
        public var id: String
        public var house: House
        public var unitType: UnitType
        public var hitPoints: Int
        public var position: PackedPosition
        public var orientation: Int
        public var action: UnitAction

        public init(
            id: String, house: House, unitType: UnitType, hitPoints: Int,
            position: PackedPosition, orientation: Int, action: UnitAction
        ) {
            self.id = id
            self.house = house
            self.unitType = unitType
            self.hitPoints = hitPoints
            self.position = position
            self.orientation = orientation
            self.action = action
        }
    }

    /// Parsed row from the `[TEAMS]` INI section:
    /// `N=House,Action,MovementType,MinMembers,MaxMembers`. Drives the
    /// enemy-wave AI — each team gets an EMC script (via TEAM.EMC) that
    /// on each tick recruits idle units with a matching movement type,
    /// finds targets, and coordinates attacks.
    public struct TeamSpawn: Sendable {
        public var id: String
        public var house: House
        /// The team's initial `action`, used to pick the TEAM.EMC entry
        /// point + stored as `actionStart` so `Team_Load2` can reset.
        public var action: TeamAction
        /// `UnitInfo.MovementType.rawValue`. Restricts which unit types
        /// `Script_Team_AddClosestUnit` may recruit.
        public var movementType: UInt16
        public var minMembers: UInt16
        public var maxMembers: UInt16

        public init(
            id: String, house: House, action: TeamAction,
            movementType: UInt16, minMembers: UInt16, maxMembers: UInt16
        ) {
            self.id = id
            self.house = house
            self.action = action
            self.movementType = movementType
            self.minMembers = minMembers
            self.maxMembers = maxMembers
        }
    }

    /// Action categorical for teams, matching OpenDUNE's
    /// `TeamActionType` (`src/team.h:11`). Named with the `team` prefix
    /// to keep it distinct from `Scenario.UnitAction`.
    public enum TeamAction: String, Sendable, CaseIterable {
        case normal = "Normal"
        case staging = "Staging"
        case flee = "Flee"
        case kamikaze = "Kamikaze"
        case guard_ = "Guard"

        public static func parse(_ s: String) -> TeamAction? {
            let lower = s.lowercased()
            return TeamAction.allCases.first(where: { $0.rawValue.lowercased() == lower })
        }

        /// OpenDUNE `TeamActionType` numeric ID — stored in `TeamSlot.action`.
        public var typeID: UInt8 {
            switch self {
            case .normal:   return 0
            case .staging:  return 1
            case .flee:     return 2
            case .kamikaze: return 3
            case .guard_:   return 4
            }
        }
    }

    public struct StructureSpawn: Sendable {
        public var id: String
        public var house: House
        public var structureType: StructureType
        public var hitPoints: Int
        public var position: PackedPosition
        /// `GEN`-prefixed rows place slabs / walls at the position encoded in
        /// the key itself rather than in the value's position field.
        public var isGenerated: Bool

        public init(
            id: String, house: House, structureType: StructureType, hitPoints: Int,
            position: PackedPosition, isGenerated: Bool
        ) {
            self.id = id
            self.house = house
            self.structureType = structureType
            self.hitPoints = hitPoints
            self.position = position
            self.isGenerated = isGenerated
        }
    }

    public enum LoadError: Error, Equatable, Sendable {
        case missingSection(String)
        case malformedRow(section: String, key: String, reason: String)
        case unknownHouse(String)
        case unknownUnitType(String)
        case unknownStructureType(String)
        case unknownAction(String)
        case unknownBrain(String)
    }

    public var briefing: Briefing = Briefing()
    public var mapField: MapField = MapField()
    public var houses: [House: HouseLayout] = [:]
    public var units: [UnitSpawn] = []
    public var structures: [StructureSpawn] = []
    public var teams: [TeamSpawn] = []

    /// Initial CHOAM (STARPORT) inventory. Port of OpenDUNE
    /// `g_starportAvailable` (`src/unit.c:57`) + its INI loader
    /// `Scenario_Load_Choam` (`src/scenario.c:473`). Indexed by unit-type
    /// ID (`UnitInfo.lookup` / `UnitType.typeID`); the 27-entry backing
    /// matches the save-format `SaveInfo.starportAvailable` array and
    /// OpenDUNE's UNIT_MAX. Non-listed entries stay at 0 (no stock),
    /// matching the `memset(..., 0, sizeof)` baseline at `opendune.c:1518`.
    /// Scenarios without a `[CHOAM]` section keep the all-zero default.
    public var choamInventory: [Int16] = [Int16](repeating: 0, count: 27)

    /// Playable tile rect for the scenario's `MapScale`. Port of
    /// OpenDUNE `g_mapInfos[3]` (`src/map.c:57`):
    ///   scale 0 → 62×62 at (1,1)   (large — campaign end-game)
    ///   scale 1 → 32×32 at (16,16) (medium — mission 1 etc.)
    ///   scale 2 → 21×21 at (21,21) (small — early briefings)
    /// Unknown scales fall back to the medium preset. Tiles outside
    /// this rect should render as `TileResolver.veiledTileID` — the
    /// off-map shadow that OpenDUNE paints around every playable
    /// area.
    public var playableRect: (originX: Int, originY: Int, width: Int, height: Int) {
        switch briefing.mapScale {
        case 0: return (1, 1, 62, 62)
        case 2: return (21, 21, 21, 21)
        default: return (16, 16, 32, 32)
        }
    }

    /// Zero-valued scenario: empty houses / units / structures, no map
    /// features, seed = 0. Used by tests and by callers that compose a
    /// scenario by hand rather than decoding INI.
    public init() {}

    public init(iniData: Data) throws {
        let doc = try Formats.Ini.Document.decode(iniData)
        try self.init(document: doc)
    }

    public init(document doc: Formats.Ini.Document) throws {
        try loadBasic(doc)
        try loadMap(doc)
        try loadHouses(doc)
        try loadUnits(doc)
        try loadStructures(doc)
        try loadTeams(doc)
        loadChoam(doc)
    }

    private mutating func loadBasic(_ doc: Formats.Ini.Document) throws {
        guard let s = doc["BASIC"] else { return }
        briefing.losePicture = s.value(forKey: "LosePicture") ?? ""
        briefing.winPicture = s.value(forKey: "WinPicture") ?? ""
        briefing.briefPicture = s.value(forKey: "BriefPicture") ?? ""
        briefing.timeOut = s.integerValue(forKey: "TimeOut") ?? 0
        briefing.mapScale = s.integerValue(forKey: "MapScale") ?? 1
        briefing.cursorPos = UInt16(s.integerValue(forKey: "CursorPos") ?? 0)
        briefing.tacticalPos = UInt16(s.integerValue(forKey: "TacticalPos") ?? 0)
        briefing.loseFlags = s.integerValue(forKey: "LoseFlags") ?? 0
        briefing.winFlags = s.integerValue(forKey: "WinFlags") ?? 0
    }

    private mutating func loadMap(_ doc: Formats.Ini.Document) throws {
        guard let s = doc["MAP"] else { return }
        if let field = s.integerListValue(forKey: "Field") {
            mapField.initialSpiceFields = field.map { UInt16($0) }
        }
        if let bloom = s.integerListValue(forKey: "Bloom") {
            mapField.initialBlooms = bloom.map { UInt16($0) }
        }
        if let special = s.integerListValue(forKey: "Special") {
            mapField.initialSpecials = special.map { UInt16($0) }
        }
        if let seed = s.integerValue(forKey: "Seed") {
            mapField.seed = UInt32(truncatingIfNeeded: seed)
        }
    }

    private mutating func loadHouses(_ doc: Formats.Ini.Document) throws {
        for house in House.allCases {
            guard let s = doc[house.rawValue] else { continue }
            var layout = HouseLayout()
            layout.quota = s.integerValue(forKey: "Quota") ?? 0
            layout.credits = s.integerValue(forKey: "Credits") ?? 0
            if let brainStr = s.value(forKey: "Brain") {
                guard let brain = HouseBrain.parse(brainStr) else {
                    throw LoadError.unknownBrain(brainStr)
                }
                layout.brain = brain
            }
            layout.maxUnits = s.integerValue(forKey: "MaxUnit") ?? 0
            houses[house] = layout
        }
    }

    private mutating func loadUnits(_ doc: Formats.Ini.Document) throws {
        guard let s = doc["UNITS"] else { return }
        units.reserveCapacity(s.entries.count)
        for entry in s.entries {
            let fields = entry.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6 else {
                throw LoadError.malformedRow(section: "UNITS", key: entry.key, reason: "expected 6 fields, got \(fields.count)")
            }
            guard let house = House.parse(fields[0]) else { throw LoadError.unknownHouse(fields[0]) }
            guard let type = UnitType.parse(fields[1]) else { throw LoadError.unknownUnitType(fields[1]) }
            guard let hp = Int(fields[2]) else {
                throw LoadError.malformedRow(section: "UNITS", key: entry.key, reason: "bad hit points \(fields[2])")
            }
            guard let pos = Int(fields[3]) else {
                throw LoadError.malformedRow(section: "UNITS", key: entry.key, reason: "bad position \(fields[3])")
            }
            guard let orientation = Int(fields[4]) else {
                throw LoadError.malformedRow(section: "UNITS", key: entry.key, reason: "bad orientation \(fields[4])")
            }
            guard let action = UnitAction.parse(fields[5]) else { throw LoadError.unknownAction(fields[5]) }
            units.append(UnitSpawn(
                id: entry.key,
                house: house,
                unitType: type,
                hitPoints: hp,
                position: PackedPosition(raw: UInt16(pos)),
                orientation: orientation,
                action: action
            ))
        }
    }

    private mutating func loadStructures(_ doc: Formats.Ini.Document) throws {
        guard let s = doc["STRUCTURES"] else { return }
        structures.reserveCapacity(s.entries.count)
        for entry in s.entries {
            let fields = entry.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let keyUpper = entry.key.uppercased()
            let isGenerated = keyUpper.hasPrefix("GEN")
            // Generated slab / wall rows may be as short as `house,type`
            // — mission 2+ writes `GEN1388=Ordos,Concrete` (2 fields).
            // Full structure rows are `house,type,hp,position`.
            let minFields = isGenerated ? 2 : 4
            guard fields.count >= minFields else {
                throw LoadError.malformedRow(section: "STRUCTURES", key: entry.key, reason: "expected >= \(minFields) fields")
            }
            guard let house = House.parse(fields[0]) else { throw LoadError.unknownHouse(fields[0]) }
            guard let type = StructureType.parse(fields[1]) else {
                throw LoadError.unknownStructureType(fields[1])
            }
            // Generated rows without an explicit HP default to 256 (max).
            // Mission 2's `GEN1388=Ordos,Concrete` relies on this.
            let hp: Int
            if fields.count >= 3, let v = Int(fields[2]) {
                hp = v
            } else if isGenerated {
                hp = 256
            } else {
                throw LoadError.malformedRow(section: "STRUCTURES", key: entry.key, reason: "bad hit points")
            }
            let position: PackedPosition
            if isGenerated {
                let digits = entry.key.dropFirst(3)
                guard let raw = UInt16(digits) else {
                    throw LoadError.malformedRow(section: "STRUCTURES", key: entry.key, reason: "GEN-key lacks digits")
                }
                position = PackedPosition(raw: raw)
            } else {
                guard let posRaw = Int(fields[3]) else {
                    throw LoadError.malformedRow(section: "STRUCTURES", key: entry.key, reason: "bad position \(fields[3])")
                }
                position = PackedPosition(raw: UInt16(posRaw))
            }
            structures.append(StructureSpawn(
                id: entry.key,
                house: house,
                structureType: type,
                hitPoints: hp,
                position: position,
                isGenerated: isGenerated
            ))
        }
    }

    /// Parses `[TEAMS]` — one row per team slot. Format:
    /// `N=House,Action,MovementType,MinMembers,MaxMembers`.
    /// Mission 1 has no [TEAMS] section; later missions carry up to
    /// ~13 team rows per house. Missing / empty section is fine.
    private mutating func loadTeams(_ doc: Formats.Ini.Document) throws {
        guard let s = doc["TEAMS"] else { return }
        teams.reserveCapacity(s.entries.count)
        for entry in s.entries {
            let fields = entry.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 5 else {
                throw LoadError.malformedRow(
                    section: "TEAMS", key: entry.key,
                    reason: "expected 5 fields, got \(fields.count)"
                )
            }
            guard let house = House.parse(fields[0]) else { throw LoadError.unknownHouse(fields[0]) }
            guard let action = TeamAction.parse(fields[1]) else {
                throw LoadError.unknownAction(fields[1])
            }
            guard let movementType = Self.parseMovementType(fields[2]) else {
                throw LoadError.malformedRow(
                    section: "TEAMS", key: entry.key,
                    reason: "unknown movement type \(fields[2])"
                )
            }
            guard let minMembers = Int(fields[3]), let maxMembers = Int(fields[4]) else {
                throw LoadError.malformedRow(
                    section: "TEAMS", key: entry.key,
                    reason: "bad min/max \(fields[3])/\(fields[4])"
                )
            }
            teams.append(TeamSpawn(
                id: entry.key,
                house: house,
                action: action,
                movementType: UInt16(movementType),
                minMembers: UInt16(clamping: minMembers),
                maxMembers: UInt16(clamping: maxMembers)
            ))
        }
    }

    /// Port of OpenDUNE `Scenario_Load_Choam` (`src/scenario.c:473`).
    /// Reads the `[CHOAM]` section's `UnitTypeName=count` rows and
    /// stores each count at `choamInventory[unitTypeID]`. Unknown
    /// unit-type strings are silently skipped (matches OpenDUNE's
    /// `Unit_StringToType == UNIT_INVALID` guard). Counts are parsed
    /// as `Int16` and saturated; out-of-range or malformed values drop
    /// to zero rather than throwing, since CHOAM is cosmetic during
    /// scenario load — bad data degrades gracefully to "no stock".
    private mutating func loadChoam(_ doc: Formats.Ini.Document) {
        guard let s = doc["CHOAM"] else { return }
        for entry in s.entries {
            guard let kind = UnitType.parse(entry.key) else {
                Log.debug(
                    "CHOAM row '\(entry.key)=\(entry.value)' — unknown unit type, skipping",
                    tracer: .label("scenario")
                )
                continue
            }
            let typeID = Int(kind.typeID)
            guard typeID >= 0, typeID < choamInventory.count else { continue }
            let count = Int16(clamping: Int(entry.value) ?? 0)
            choamInventory[typeID] = count
            Log.debug(
                "CHOAM \(kind.rawValue) (type=\(typeID)) → \(count)",
                tracer: .label("scenario")
            )
        }
    }

    /// Maps INI movement-type strings to the numeric ID used by
    /// `Simulation.MovementType.rawValue` — matches OpenDUNE's
    /// `MovementType` enum in `src/unit.h`.
    private static func parseMovementType(_ name: String) -> Int? {
        switch name.lowercased() {
        case "foot":      return 0
        case "tracked":   return 1
        case "harvester": return 2
        case "wheeled":   return 3
        case "winger":    return 4
        case "slither":   return 5
        default:          return nil
        }
    }
}
