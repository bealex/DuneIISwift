/// The state of a structure. A port of OpenDUNE's `StructureState` (`src/structure.h`). Signed:
/// `detect`/`justBuilt` are negative sentinels.
public enum StructureState: Int16, Sendable, Equatable {
    case detect = -2        // when setting: detect the state from other properties
    case justBuilt = -1     // shows the building animation
    case idle = 0
    case busy = 1           // harvester in refinery, unit in repair, …
    case ready = 2          // ready; a unit will be deployed soon
}

/// A structure in the game. A port of OpenDUNE's `Structure` struct (`src/structure.h`); embeds an
/// `Object` as `o`.
public struct Structure: Sendable, Equatable {
    public var o: Object = Object()
    public var creatorHouseID: UInt16 = 0       // house that created it (for take-overs)
    public var rotationSpriteDiff: UInt16 = 0   // sprite for the current turret rotation
    public var objectType: UInt16 = 0           // type of unit/structure being built
    public var upgradeLevel: UInt8 = 0
    public var upgradeTimeLeft: UInt8 = 0        // 0 = no upgrade available
    public var countDown: UInt16 = 0            // general countdown
    public var buildCostRemainder: UInt16 = 0   // buildCost remainder for the next tick
    public var state: StructureState = .idle
    public var hitpointsMax: UInt16 = 0

    public init() {}
}
