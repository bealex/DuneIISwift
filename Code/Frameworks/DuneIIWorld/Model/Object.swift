/// The data common to a `Unit` and a `Structure`. A port of OpenDUNE's `Object` struct
/// (`src/object.h`), embedded by both as the field `o`.
public struct Object: Sendable, Equatable, Codable {
    public var index: UInt16 = 0            // index in the owning pool
    public var type: UInt8 = 0              // UnitType / StructureType
    public var linkedID: UInt8 = 0xFF       // linked Structure/Unit, or 0xFF if none
    public var flags: ObjectFlags = []
    public var houseID: UInt8 = 0
    public var seenByHouses: UInt8 = 0      // bitmask of houses that have seen this object
    public var position: Tile32 = Tile32(x: 0, y: 0)
    public var hitpoints: UInt16 = 0
    public var script: ScriptEngine = ScriptEngine()

    public init() {}
}
