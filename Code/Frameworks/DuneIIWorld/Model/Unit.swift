/// Directional state, one per orientation slot. A port of OpenDUNE's `dir24` (`src/unit.h`).
public struct Dir24: Sendable, Equatable, Codable {
    public var speed: Int8 = 0      // speed of direction change
    public var target: Int8 = 0     // target direction
    public var current: Int8 = 0    // current direction

    public init() {}
}

/// A unit in the game. A port of OpenDUNE's `Unit` struct (`src/unit.h`); embeds an `Object` as `o`.
public struct Unit: Sendable, Equatable, Codable {
    public var o: Object = Object()
    public var currentDestination: Tile32 = Tile32(x: 0, y: 0)
    public var originEncoded: UInt16 = 0
    public var actionID: UInt8 = 0
    public var nextActionID: UInt8 = 0
    public var fireDelay: UInt16 = 0            // uint8 in Dune2; uint16 here per OpenDUNE
    public var distanceToDestination: UInt16 = 0
    public var targetAttack: UInt16 = 0         // encoded index
    public var targetMove: UInt16 = 0           // encoded index
    public var amount: UInt8 = 0                // sandworm: units left to eat; harvester: spice held
    public var deviated: UInt8 = 0              // deviation strength (0 = not deviated)
    public var deviatedHouse: UInt8 = 0         // house deviated to (valid only if deviated != 0)
    public var targetLast: Tile32 = Tile32(x: 0, y: 0)
    public var targetPreLast: Tile32 = Tile32(x: 0, y: 0)
    public var orientation: [Dir24] = [Dir24(), Dir24()]   // [0] base, [1] top (turret)
    public var speedPerTick: UInt8 = 0
    public var speedRemainder: UInt8 = 0
    public var speed: UInt8 = 0
    public var movingSpeed: UInt8 = 0
    public var wobbleIndex: UInt8 = 0
    public var spriteOffset: Int8 = 0
    public var blinkCounter: UInt8 = 0
    public var team: UInt8 = 0                  // 0 = none; value n means team n-1
    public var timer: UInt16 = 0
    public var route: [UInt8] = Array(repeating: 0, count: 14)

    public init() {}
}
