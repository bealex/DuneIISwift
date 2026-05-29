/// The 19 structure types, in the engine's canonical order. A port of OpenDUNE's `StructureType`
/// (`src/structure.h:11`); `rawValue` matches `STRUCTURE_SLAB_1x1 … STRUCTURE_OUTPOST` (0…18,
/// `STRUCTURE_MAX` = 19). The original's `STRUCTURE_INVALID` (0xFF) is represented by an optional
/// `StructureType?` rather than a case.
///
/// Lives in Contracts as a shared seam identifier (sim ↔ render ↔ input ↔ save), alongside `HouseID`.
public enum StructureType: Int, CaseIterable, Sendable {
    case slab1x1 = 0
    case slab2x2 = 1
    case palace = 2
    case lightVehicle = 3
    case heavyVehicle = 4
    case highTech = 5
    case houseOfIx = 6
    case worTrooper = 7
    case constructionYard = 8
    case windtrap = 9
    case barracks = 10
    case starport = 11
    case refinery = 12
    case repair = 13
    case wall = 14
    case turret = 15
    case rocketTurret = 16
    case silo = 17
    case outpost = 18
}
