/// A script engine instance, owned by an `Object` or a `Team`. A port of OpenDUNE's `ScriptEngine`
/// (`src/script/script.h`).
///
/// Deviation: OpenDUNE's `uint16 *script` (a pointer to the current command) is stored here as
/// `scriptPC` — its offset from `scriptInfo->start`, the same form the save format and the parity
/// harness use. A NULL `script` pointer (no script loaded, or after a fatal scripting error) is the
/// sentinel `scriptPC == scriptNull` (`0xFFFF`); a C `NULL` pointer can't be confused with offset 0,
/// but our offsets can, so we reserve the top value. The `scriptInfo` pointer itself is re-derived at
/// runtime from the owner's type and is not stored.
public struct ScriptEngine: Sendable, Equatable {
    /// `scriptPC` value standing in for OpenDUNE's NULL `script` pointer (not loaded / errored).
    public static let scriptNull: UInt16 = 0xFFFF

    public var delay: UInt16 = 0                    // ticks the script is suspended (0 = running)
    public var scriptPC: UInt16 = scriptNull        // offset from scriptInfo.start, or scriptNull (NULL)
    public var returnValue: UInt16 = 0      // return value from sub-routines
    public var framePointer: UInt8 = 0
    public var stackPointer: UInt8 = 0
    public var variables: [UInt16] = Array(repeating: 0, count: 5)   // outside-stack storage
    public var stack: [UInt16] = Array(repeating: 0, count: 15)      // engine stack (fills from the end)
    public var isSubroutine: UInt8 = 0      // the executing script is a sub-routine

    public init() {}

    /// `Script_Reset` (`script/script.c`): drop any running script (`scriptPC = scriptNull`) and re-home
    /// the frame/stack pointers to the literal OpenDUNE init values (17 / 15). OpenDUNE also re-stores
    /// the `scriptInfo` pointer, which we don't model (it's supplied per call, re-derived from the type).
    public mutating func reset() {
        scriptPC = ScriptEngine.scriptNull
        isSubroutine = 0
        framePointer = 17
        stackPointer = 15
    }

    /// `STACK_PEEK(position)` (1-based): read a value off the stack without popping it — how the native
    /// script functions read their arguments. Returns 0 if `position` is out of range (the VM glue only
    /// peeks arguments a running script has pushed; a defensive read avoids a trap on malformed input).
    public func peek(_ position: Int) -> UInt16 {
        let i = Int(stackPointer) + position - 1
        return (i >= 0 && i < stack.count) ? stack[i] : 0
    }
}
