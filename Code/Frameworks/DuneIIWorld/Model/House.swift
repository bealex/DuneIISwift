import DuneIIContracts

/// General flags of a house. A port of OpenDUNE's `HouseFlags` (`src/house.h`), modelled as an
/// `OptionSet<UInt8>` (5 bits used). Bit positions in C declaration order.
public struct HouseFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let used                = HouseFlags(rawValue: 1 << 0)
    public static let human               = HouseFlags(rawValue: 1 << 1)  // human-controlled
    public static let doneFullScaleAttack = HouseFlags(rawValue: 1 << 2)  // did its one-time all-out attack
    public static let isAIActive          = HouseFlags(rawValue: 1 << 3)  // seen by human → AI fully active
    public static let radarActivated      = HouseFlags(rawValue: 1 << 4)
}

/// A house in the game. A port of OpenDUNE's `House` struct (`src/house.h`). Keyed in the pool by
/// `index` (a `HouseID`).
public struct House: Sendable, Equatable {
    public var index: UInt8 = 0
    public var harvestersIncoming: UInt16 = 0   // harvesters waiting to be delivered
    public var flags: HouseFlags = []
    public var unitCount: UInt16 = 0
    public var unitCountMax: UInt16 = 0
    public var unitCountEnemy: UInt16 = 0
    public var unitCountAllied: UInt16 = 0
    public var structuresBuilt: UInt32 = 0      // bit N = structure type N is built (one or more)
    public var credits: UInt16 = 0
    public var creditsStorage: UInt16 = 0
    public var powerProduction: UInt16 = 0
    public var powerUsage: UInt16 = 0
    public var windtrapCount: UInt16 = 0
    public var creditsQuota: UInt16 = 0         // quota to reach to win
    public var palacePosition: Tile32 = Tile32(x: 0, y: 0)
    public var timerUnitAttack: UInt16 = 0
    public var timerSandwormAttack: UInt16 = 0
    public var timerStructureAttack: UInt16 = 0
    public var starportTimeLeft: UInt16 = 0
    public var starportLinkedID: UInt16 = 0xFFFF    // first unit of the delivery list, or 0xFFFF
    /// AI rebuild memory: `[5][2]` of (type, position) for destroyed structures to rebuild.
    public var aiStructureRebuild: [[UInt16]] = Array(repeating: [0, 0], count: 5)

    public init() {}
}
