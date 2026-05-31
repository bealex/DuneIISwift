/// What a team is currently doing. A port of OpenDUNE's `TeamActionType` (`src/team.h`).
public enum TeamActionType: Int, Sendable, Equatable, Codable, CaseIterable {
    case normal = 0
    case staging = 1
    case flee = 2
    case kamikaze = 3
    case guard_ = 4
}

/// General flags of a team. A port of OpenDUNE's `TeamFlags` (`src/team.h`); only `used` is defined.
public struct TeamFlags: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let used = TeamFlags(rawValue: 1 << 0)
}

/// A team of units. A port of OpenDUNE's `Team` struct (`src/team.h`); owns a `ScriptEngine`.
public struct Team: Sendable, Equatable, Codable {
    public var index: UInt16 = 0
    public var flags: TeamFlags = []
    public var members: UInt16 = 0
    public var minMembers: UInt16 = 0
    public var maxMembers: UInt16 = 0
    public var movementType: UInt16 = 0     // MovementType
    public var action: UInt16 = 0           // current TeamActionType
    public var actionStart: UInt16 = 0      // the TeamActionType it starts with
    public var houseID: UInt8 = 0
    public var position: Tile32 = Tile32(x: 0, y: 0)
    public var targetTile: UInt16 = 0       // used as a bool (set or not)
    public var target: UInt16 = 0           // encoded index
    public var script: ScriptEngine = ScriptEngine()

    public init() {}
}
