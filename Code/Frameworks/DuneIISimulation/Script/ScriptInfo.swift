import DuneIIFormats

/// The loaded program a `ScriptEngine` runs against — OpenDUNE's `ScriptInfo` (`src/script/script.h`),
/// reduced to what the VM core needs: the bytecode words (`scriptInfo->start`) and the per-type entry
/// offsets (`scriptInfo->offsets`). The `functions` table (op-14 natives) is supplied separately at run
/// time (a category's 64 `Script_*` functions), so it isn't stored here. `text` (string table) is only
/// used by display natives and is omitted until those land.
public struct ScriptInfo: Sendable, Equatable {
    /// `scriptInfo->start`: the bytecode words, already host-order (the Formats reader decoded the
    /// big-endian `DATA` chunk), so the VM indexes `program[scriptPC]` with no byte-swap.
    public let program: [UInt16]
    /// `scriptInfo->offsets`: per-`typeID` entry, a word index into `program`.
    public let offsets: [UInt16]

    public init(program: [UInt16], offsets: [UInt16]) {
        self.program = program
        self.offsets = offsets
    }

    /// Bridge from the Formats EMC reader (`Emc.Program`): `DATA` words → `program`, `ORDR` → `offsets`.
    public init(_ emc: Emc.Program) {
        self.program = emc.data
        self.offsets = emc.offsets.map { UInt16(truncatingIfNeeded: $0) }
    }
}
