import DuneIIContracts

/// One of the predefined behavioural scenarios. See `Documentation/Architecture/ScenarioHarness.md`.
public enum ScenarioKind: String, Sendable, CaseIterable {
    case moving
    case closeAttack
    case farAttack
    case guarding
    case moveAroundBuilding
    case deviate

    public var title: String {
        switch self {
            case .moving:             return "Moving (0:0 → 7:7)"
            case .closeAttack:        return "Close attack"
            case .farAttack:          return "Far attack"
            case .guarding:           return "Guarding (react at 2:2)"
            case .moveAroundBuilding: return "Move around building"
            case .deviate:            return "Deviate (enemy steals the unit)"
        }
    }

    /// Whether the scenario uses a second unit (everything but plain moving).
    public var usesSecondUnit: Bool { self != .moving }
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
