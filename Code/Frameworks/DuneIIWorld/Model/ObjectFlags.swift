/// General runtime flags common to a unit and a structure. A port of OpenDUNE's `ObjectFlags` union
/// (`src/object.h`); the union's `uint32 all` is the `rawValue`, with bit positions in C declaration
/// order. Round-trips through `all` in the save format, so the layout is golden-pinned against the
/// oracle — see `Documentation/Architecture/DataModel.md`.
public struct ObjectFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let used           = ObjectFlags(rawValue: 1 << 0)   // in use (not free in the pool)
    public static let allocated      = ObjectFlags(rawValue: 1 << 1)   // created, ready to place on the map
    public static let isNotOnMap     = ObjectFlags(rawValue: 1 << 2)   // under construction / in refinery / etc.
    public static let isSmoking      = ObjectFlags(rawValue: 1 << 3)   // emitting a smoke cloud
    public static let fireTwiceFlip  = ObjectFlags(rawValue: 1 << 4)   // unit fire-twice: tracks the 2nd shot
    public static let animationFlip  = ObjectFlags(rawValue: 1 << 5)   // bullet/missile: alternate sprite group
    public static let bulletIsBig    = ObjectFlags(rawValue: 1 << 6)   // bullet/sonic wave drawn twice as big
    public static let isWobbling     = ObjectFlags(rawValue: 1 << 7)   // wobbles during movement
    public static let inTransport    = ObjectFlags(rawValue: 1 << 8)   // in transport (spaceport / carryall / …)
    public static let byScenario     = ObjectFlags(rawValue: 1 << 9)   // created by the scenario
    public static let degrades       = ObjectFlags(rawValue: 1 << 10)  // structure degrades
    public static let isHighlighted  = ObjectFlags(rawValue: 1 << 11)  // currently highlighted
    public static let isDirty        = ObjectFlags(rawValue: 1 << 12)  // redraw next update
    public static let repairing      = ObjectFlags(rawValue: 1 << 13)  // structure being repaired
    public static let onHold         = ObjectFlags(rawValue: 1 << 14)  // structure on hold
    public static let isUnit         = ObjectFlags(rawValue: 1 << 16)  // true = unit, false = structure
    public static let upgrading      = ObjectFlags(rawValue: 1 << 17)  // structure being upgraded
}
