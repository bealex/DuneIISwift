/// A script engine instance, owned by an `Object` or a `Team`. A port of OpenDUNE's `ScriptEngine`
/// (`src/script/script.h`).
///
/// Deviation: OpenDUNE's `uint16 *script` (a pointer to the current command) is stored here as
/// `scriptPC` — its offset from `scriptInfo->start`, the same form the save format and the parity
/// harness use. The `scriptInfo` pointer itself is re-derived at runtime from the owner's type and is
/// not stored.
public struct ScriptEngine: Sendable, Equatable {
    public var delay: UInt16 = 0            // ticks the script is suspended (0 = running)
    public var scriptPC: UInt16 = 0         // offset of the current command from scriptInfo.start
    public var returnValue: UInt16 = 0      // return value from sub-routines
    public var framePointer: UInt8 = 0
    public var stackPointer: UInt8 = 0
    public var variables: [UInt16] = Array(repeating: 0, count: 5)   // outside-stack storage
    public var stack: [UInt16] = Array(repeating: 0, count: 15)      // engine stack (fills from the end)
    public var isSubroutine: UInt8 = 0      // the executing script is a sub-routine

    public init() {}

    /// `Script_Reset` (`script/script.c`): drop any running script and re-home the frame/stack pointers.
    /// OpenDUNE also sets `script->script = NULL` (no active command) and `scriptInfo = scriptInfo`; we
    /// store neither pointer (see the type note — `scriptPC` is an offset and `scriptInfo` is re-derived
    /// from the owner's type), so this resets only the modeled numeric state. The frame/stack pointers
    /// take the literal OpenDUNE init values (17 / 15).
    public mutating func reset() {
        isSubroutine = 0
        framePointer = 17
        stackPointer = 15
    }
}
