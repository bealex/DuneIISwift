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

public extension GameState {
    /// Load a scenario `.INI` into this state: derive the tile-id bases + generate the landscape from
    /// `BASIC/Seed`, set the map scale, and place the `[UNITS]` and `[STRUCTURES]`. A pragmatic port of
    /// `Scenario_Load*` (`src/scenario.c`) — enough to populate a drawable/simulatable `GameState`.
    mutating func loadScenario(ini: Ini, iconMap: IconMap) {
        tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        mapScale = UInt8(clamping: ini.integer(section: "BASIC", key: "MapScale"))
        let seed = UInt32(bitPattern: Int32(truncatingIfNeeded: ini.integer(section: "MAP", key: "Seed")))
        createLandscape(seed: seed, iconMap: iconMap)

        // Loading bypasses the per-house unit cap (OpenDUNE bumps g_validateStrictIfZero).
        let savedStrict = validateStrictIfZero
        validateStrictIfZero = 1
        defer { validateStrictIfZero = savedStrict }

        for key in ini.keys(section: "UNITS") { loadUnit(ini.string(section: "UNITS", key: key)) }
        for key in ini.keys(section: "STRUCTURES") {
            loadStructure(key: key, value: ini.string(section: "STRUCTURES", key: key))
        }

        // Stamp each structure's tiles onto the map + start its idle animation.
        for index in structures.indices where structures[index].o.flags.contains(.used) {
            structureUpdateMap(index)
        }
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

    private func fields(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
