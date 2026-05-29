/// The 27 unit types, in the engine's canonical order. A port of OpenDUNE's `UnitType`
/// (`src/unit.h:11`); `rawValue` matches `UNIT_CARRYALL … UNIT_FRIGATE` (0…26, `UNIT_MAX` = 27).
/// The original's `UNIT_INVALID` (0xFF) is represented by an optional `UnitType?` rather than a case.
///
/// Lives in Contracts as a shared seam identifier (sim ↔ render ↔ input ↔ save), alongside `HouseID`.
public enum UnitType: Int, CaseIterable, Sendable {
    case carryall = 0
    case ornithopter = 1
    case infantry = 2
    case troopers = 3
    case soldier = 4
    case trooper = 5
    case saboteur = 6
    case launcher = 7
    case deviator = 8
    case tank = 9
    case siegeTank = 10
    case devastator = 11
    case sonicTank = 12
    case trike = 13
    case raiderTrike = 14
    case quad = 15
    case harvester = 16
    case mcv = 17
    case missileHouse = 18
    case missileRocket = 19
    case missileTurret = 20
    case missileDeviator = 21
    case missileTrooper = 22
    case bullet = 23
    case sonicBlast = 24
    case sandworm = 25
    case frigate = 26
}
