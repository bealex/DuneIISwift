import DuneIIContracts

/// One of the predefined behavioural scenarios. See `Documentation/Architecture/ScenarioHarness.md`.
public enum ScenarioKind: String, Sendable, CaseIterable {
    case moving
    case closeAttack
    case farAttack
    case guarding
    case moveAroundBuilding
    case deviate
    case attackStructure
    case turretDefense
    case factoryProduce
    case repairBuilding
    case upgradeBuilding
    case sandwormEating

    public var title: String {
        switch self {
            case .moving:             return "Moving (0:0 → 7:7)"
            case .closeAttack:        return "Close attack"
            case .farAttack:          return "Far attack"
            case .guarding:           return "Guarding (react at 2:2)"
            case .moveAroundBuilding: return "Move around building"
            case .deviate:            return "Deviate (enemy steals the unit)"
            case .attackStructure:    return "Attack a building (→ destroyed)"
            case .turretDefense:      return "Turret defends (fires at an attacker)"
            case .factoryProduce:     return "Factory builds a unit (credits drain → READY)"
            case .repairBuilding:     return "Building self-repairs (HP climbs)"
            case .upgradeBuilding:    return "Building upgrades (level up)"
            case .sandwormEating:     return "Sandworm eats a unit (swallow animation)"
        }
    }

    /// Whether the scenario uses a second *unit*. The single-unit / structure-only scenarios don't.
    public var usesSecondUnit: Bool {
        switch self {
            case .moving, .attackStructure, .factoryProduce, .repairBuilding, .upgradeBuilding: return false
            default: return true
        }
    }
}

/// A fully-specified scenario: which behaviour, the two chosen unit types, and the terrain seed (which
/// pins the constant terrain for the golden comparison).
public struct TestScenario: Sendable, Equatable {
    public let kind: ScenarioKind
    public let unit1: UnitType
    public let unit2: UnitType
    public let terrainSeed: UInt32

    public init(kind: ScenarioKind, unit1: UnitType, unit2: UnitType, terrainSeed: UInt32) {
        self.kind = kind
        self.unit1 = unit1
        self.unit2 = unit2
        self.terrainSeed = terrainSeed
    }
}
