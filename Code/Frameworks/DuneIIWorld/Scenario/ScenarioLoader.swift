import DuneIIContracts
import DuneIIFormats

/// Name → type lookups, matching the strings used in scenario `.INI` files against the stat-table
/// names (OpenDUNE's `*_StringToType`).
public extension HouseID {
    static func named(_ name: String) -> HouseID? {
        allCases.first { HouseInfo[$0].name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public extension UnitType {
    static func named(_ name: String) -> UnitType? {
        allCases.first { UnitInfo[$0].o.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public extension StructureType {
    static func named(_ name: String) -> StructureType? {
        allCases.first { StructureInfo[$0].o.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public extension MovementType {
    /// `Unit_MovementStringToType` (`unit.c:375`, `g_table_movementTypeName`). Note "Winged" → `.winger`.
    static func named(_ name: String) -> MovementType? {
        let names = ["Foot", "Tracked", "Harvester", "Wheeled", "Winged", "Slither"]
        guard let i = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return MovementType(rawValue: i)
    }
}

public extension TeamActionType {
    /// `Team_ActionStringToType` (`team.c:108`, `g_table_teamActionName`).
    static func named(_ name: String) -> TeamActionType? {
        let names = ["Normal", "Staging", "Flee", "Kamikaze", "Guard"]
        guard let i = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return TeamActionType(rawValue: i)
    }
}

public extension GameState {
    /// Load a scenario `.INI` into this state: derive the tile-id bases + generate the landscape from
    /// `BASIC/Seed`, set the map scale, activate the `[HOUSES]`, and place the `[UNITS]` and `[STRUCTURES]`.
    /// A pragmatic port of `Scenario_Load*` (`src/scenario.c`) — enough to populate a
    /// drawable/simulatable `GameState`.
    mutating func loadScenario(ini: Ini, iconMap: IconMap, teamScriptOffsets: [UInt16] = []) {
        tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        mapScale = UInt8(clamping: ini.integer(section: "BASIC", key: "MapScale"))
        scenario.winFlags = UInt16(clamping: ini.integer(section: "BASIC", key: "WinFlags"))
        scenario.loseFlags = UInt16(clamping: ini.integer(section: "BASIC", key: "LoseFlags"))
        tickScenarioStart = timerGame
        gameEndState = .playing
        let seed = UInt32(bitPattern: Int32(truncatingIfNeeded: ini.integer(section: "MAP", key: "Seed")))
        createLandscape(seed: seed, iconMap: iconMap)

        // Loading bypasses the per-house unit cap (OpenDUNE bumps g_validateStrictIfZero).
        let savedStrict = validateStrictIfZero
        validateStrictIfZero = 1
        defer { validateStrictIfZero = savedStrict }

        loadMapBlooms(ini: ini)
        loadHouses(ini: ini)

        for key in ini.keys(section: "UNITS") { loadUnit(ini.string(section: "UNITS", key: key)) }
        for key in ini.keys(section: "STRUCTURES") {
            loadStructure(key: key, value: ini.string(section: "STRUCTURES", key: key))
        }
        // `[TEAMS]` = "<House>,<TeamAction>,<MovementType>,<minMembers>,<maxMembers>" → `Team_Create`.
        for key in ini.keys(section: "TEAMS") {
            loadTeam(ini.string(section: "TEAMS", key: key), offsets: teamScriptOffsets)
        }
        // `[REINFORCEMENTS]` = "<index>=<House>,<UnitType>,<Location>,<timeBetween>[+]" → the timed-spawn table.
        for key in ini.keys(section: "REINFORCEMENTS") {
            loadReinforcement(key: key, value: ini.string(section: "REINFORCEMENTS", key: key))
        }
        // `[CHOAM]` = "<UnitType>=<stock>" → seed the starport stock (`Scenario_Load_Choam`, `scenario.c:300`).
        for key in ini.keys(section: "CHOAM") {
            guard let type = UnitType.named(key), type.rawValue < starportAvailable.count else { continue }
            starportAvailable[type.rawValue] = Int16(clamping: ini.integer(section: "CHOAM", key: key))
        }

        // Stamp each structure's tiles onto the map + start its idle animation.
        for index in structures.indices where structures[index].o.flags.contains(.used) {
            structureUpdateMap(index)
        }

        // Seed each active house's power/storage from its structures (the oracle's tick-0 baseline).
        var find = PoolFind()
        while let h = houseFind(&find) { houseCalculatePowerAndCredit(houses[h].index) }
    }

    /// Activate the scenario's houses + seed their economy. Two formats are accepted:
    ///
    /// 1. **Per-house sections** (the real install format, `Scenario_Load_House` `scenario.c:50`): each
    ///    `[<HouseName>]` section carries `Brain` (HUMAN / CPU — absent/NONE ⇒ the house isn't in this
    ///    scenario), `Credits`, `Quota`, `MaxUnit` (default 39). The `Brain=Human` house becomes the player
    ///    and its starting credits seed `playerCreditsNoSilo` (so the house tick's credit clamp keeps them
    ///    without a silo — otherwise the player is clamped to near-zero storage and can't build).
    /// 2. **A flat `[HOUSES]` section** (`<HouseName>=<startingCredits>`) — the synthetic parity fixtures.
    ///
    /// Scenarios without either run with no active houses.
    private mutating func loadHouses(ini: Ini) {
        for house in HouseID.allCases {
            let name = HouseInfo[house].name
            guard let brain = ini.string(section: name, key: "Brain")?.uppercased(),
                  brain == "HUMAN" || brain == "CPU" else { continue }
            let h = houseAllocate(index: UInt8(house.rawValue)) ?? Int(house.rawValue)
            houses[h].credits = UInt16(clamping: ini.integer(section: name, key: "Credits"))
            houses[h].creditsQuota = UInt16(clamping: ini.integer(section: name, key: "Quota"))
            houses[h].unitCountMax = UInt16(clamping: ini.integer(section: name, key: "MaxUnit", default: 39))
            if brain == "HUMAN" {
                playerHouseID = UInt8(house.rawValue)
                playerCreditsNoSilo = houses[h].credits
            }
        }
        for key in ini.keys(section: "HOUSES") {
            guard let house = HouseID.named(key) else { continue }
            let h = houseAllocate(index: UInt8(house.rawValue)) ?? Int(house.rawValue)
            houses[h].credits = UInt16(clamping: Int(ini.string(section: "HOUSES", key: key) ?? "") ?? 0)
        }
    }

    /// `[MAP] Bloom` / `Special` — place the scenario's spice blooms (`Scenario_Load_Map_Bloom/_Special`,
    /// `scenario.c:96`) by stamping `tileIDs.bloom` (+1 for a "special" bloom) onto each listed packed tile,
    /// after the seed landscape is generated + converted to real tile ids. `[MAP] Field` is a `Map_Bloom_
    /// ExplodeSpice` spice-circle per tile (`scenario.c:328`) — a Simulation-layer fill — so its tiles are
    /// stashed in `scenario.spiceFields` for `Simulation.applyScenarioSpiceFields` to detonate before tick 0.
    private mutating func loadMapBlooms(ini: Ini) {
        for packed in packedList(ini.string(section: "MAP", key: "Bloom")) where Int(packed) < map.count {
            map[Int(packed)].groundTileID = tileIDs.bloom
            mapBaseTileID[Int(packed)] = tileIDs.bloom
        }
        for packed in packedList(ini.string(section: "MAP", key: "Special")) where Int(packed) < map.count {
            map[Int(packed)].groundTileID = tileIDs.bloom &+ 1
            mapBaseTileID[Int(packed)] = tileIDs.bloom &+ 1
        }
        scenario.spiceFields = packedList(ini.string(section: "MAP", key: "Field")).filter { Int($0) < map.count }
    }

    /// Parse a `[MAP]` comma-separated list of packed tile indices.
    private func packedList(_ value: String?) -> [UInt16] {
        (value ?? "").split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `House,UnitType,HP%,packedPosition,orientation,actionState`.
    private mutating func loadUnit(_ value: String?) {
        let parts = fields(value)
        guard parts.count >= 5,
              let house = HouseID.named(parts[0]),
              let type = UnitType.named(parts[1]) else { return }

        let hpPercent = Int(parts[2]) ?? 256
        let packed = UInt16(clamping: Int(parts[3]) ?? 0)
        let orientation = Int8(bitPattern: UInt8(truncatingIfNeeded: Int(parts[4]) ?? 0))

        guard let i = unitAllocate(index: Pool.unitIndexInvalid, type: UInt8(type.rawValue),
                                   houseID: UInt8(house.rawValue)) else { return }
        units[i].o.hitpoints = UInt16(hpPercent * Int(UnitInfo[type].o.hitpoints) / 256)
        units[i].o.position = Tile32.unpack(packed)
        units[i].orientation[0].current = orientation
        units[i].orientation[1].current = orientation
        units[i].o.flags.insert(.byScenario)
        // The 6th field is the action (`Unit_ActionStringToType`); record it (World can't load the script
        // — that's `Unit_SetAction`, a Simulation concern — but the action id is part of the scenario).
        if parts.count >= 6, let action = ActionType.named(parts[5]) {
            units[i].actionID = UInt8(action.rawValue)
        }
        units[i].nextActionID = 0xFF
        // Optional 7th field: a `seenByHouses` bitmask (so a turret can target a pre-seen enemy without
        // fog reveal, which the headless harness doesn't run). Absent ⇒ 0 (existing scenarios unchanged).
        if parts.count >= 7, let seen = UInt8(parts[6]) { units[i].o.seenByHouses = seen }
    }

    /// `GEN<packed>=House,StructureType` (slabs/walls) or `ID<n>=House,StructureType,HP%,packed`.
    private mutating func loadStructure(key: String, value: String?) {
        let parts = fields(value)
        let isGen = key.uppercased().hasPrefix("GEN")
        guard parts.count >= 2,
              let house = HouseID.named(parts[0]),
              let type = StructureType.named(parts[1]) else { return }

        let packed: UInt16
        if isGen {
            packed = UInt16(clamping: Int(key.dropFirst(3)) ?? 0)
        } else {
            guard parts.count >= 4 else { return }
            packed = UInt16(clamping: Int(parts[3]) ?? 0)
        }

        // Slabs and walls aren't persistent structures — `Structure_Place` stamps them into the map and
        // frees the object (they have no script, so nothing would ever stamp them later). Place + return.
        switch type {
            case .slab1x1, .slab2x2: placeSlab(type, houseID: UInt8(house.rawValue), at: packed); return
            case .wall:              placeWall(houseID: UInt8(house.rawValue), at: packed); return
            default: break
        }

        guard let i = structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))
        else { return }
        structures[i].o.houseID = UInt8(house.rawValue)
        // A structure stores its tile *corner*, not the centred sub-tile — `Structure_Place` zeroes the
        // 0x80 (`s->o.position &= 0xFF00`). Units centre; structures don't. The 128px offset matters for
        // every unit-vs-structure distance/aim calc (it shifts the firing direction onto a 2×2 footprint).
        structures[i].o.position = Tile32(x: Tile32.unpack(packed).x & 0xFF00, y: Tile32.unpack(packed).y & 0xFF00)
        structures[i].state = .idle
        // 1.07 ignores the scenario HP% — structures load at full hitpoints (`Scenario_Load_Structure`).
        structures[i].o.hitpoints = StructureInfo[type].o.hitpoints
        structures[i].hitpointsMax = StructureInfo[type].o.hitpoints
        structures[i].o.flags.remove(.degrades)
    }

    /// `<House>,<TeamAction>,<MovementType>,<minMembers>,<maxMembers>` → `Team_Create` (`Scenario_Load_Team`).
    /// `offsets` is the team `ScriptInfo`'s per-action entry table; the team's action script is loaded to
    /// `offsets[teamAction]` (or left unloaded — `scriptNull` — when no team script is supplied).
    private mutating func loadTeam(_ value: String?, offsets: [UInt16]) {
        let parts = fields(value)
        guard parts.count >= 5,
              let house = HouseID.named(parts[0]),
              let action = TeamActionType.named(parts[1]),
              let movement = MovementType.named(parts[2]) else { return }
        let minMembers = UInt16(clamping: Int(parts[3]) ?? 0)
        let maxMembers = UInt16(clamping: Int(parts[4]) ?? 0)
        let scriptPC = action.rawValue < offsets.count ? offsets[action.rawValue] : ScriptEngine.scriptNull
        teamCreate(houseID: UInt8(house.rawValue), teamActionType: UInt8(action.rawValue),
                   movementType: UInt8(movement.rawValue), minMembers: minMembers, maxMembers: maxMembers,
                   scriptPC: scriptPC)
        // Flag the team's house AI-active so `GameLoop_Team` runs it. In a real game the bit is set when the
        // AI first sees an enemy; scenario load pins it on (mirroring the parity harness's Scen_LoadTeam).
        houses[Int(house.rawValue)].flags.insert(.isAIActive)
    }

    /// `Scenario_Load_Reinforcement` (`scenario.c:280`): `<index>=<House>,<UnitType>,<Location>,<timeBetween>[+]`.
    /// `Location` is NORTH/EAST/SOUTH/WEST (0-3) or AIR/VISIBLE/ENEMYBASE/HOMEBASE (4-7); `timeBetween`
    /// is `atoi * 6 + 1`. The trailing `+` is parsed but pinned off (1.07 fires each reinforcement once —
    /// see `Reinforcement.repeats`). We store the spawn *recipe*; the Simulation creates the unit at deploy.
    private mutating func loadReinforcement(key: String, value: String?) {
        guard let index = Int(key), index >= 0, index < scenario.reinforcements.count else { return }
        let parts = fields(value)
        guard parts.count >= 4,
              let house = HouseID.named(parts[0]),
              let type = UnitType.named(parts[1]) else { return }
        let locations = ["NORTH", "EAST", "SOUTH", "WEST", "AIR", "VISIBLE", "ENEMYBASE", "HOMEBASE"]
        guard let locationID = locations.firstIndex(of: parts[2].uppercased()) else { return }

        var r = Reinforcement()
        r.unitType = UInt8(type.rawValue)
        r.houseID = UInt8(house.rawValue)
        r.locationID = UInt8(locationID)
        r.timeBetween = UInt16(clamping: (Int(parts[3].filter(\.isNumber)) ?? 0) * 6 + 1)
        r.timeLeft = r.timeBetween
        r.repeats = false   // 1.07 non-enhanced: the '+' is always dropped (`scenario.c` parse bug).
        scenario.reinforcements[index] = r
    }

    private func fields(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
