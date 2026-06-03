import DuneIIWorld
import Synchronization

/// One per-opcode decision-trace line — the Tier-2a parity unit. Captures the pre-execution state at the
/// top of a `Script_Run` (the same point + fields OpenDUNE's `--parity-script-trace` emits in
/// `script/script.c`), so our trace can be diffed against the oracle's line-by-line. See
/// `Documentation/Architecture/ParityHarness.md` / `ScenarioHarness.md`.
public struct ScriptTraceLine: Sendable, Equatable {
    public let pc: Int  // opcode offset from `scriptInfo.start`, before it is read
    public let op: Int  // decoded opcode (flags stripped; a 13-bit GOTO decodes to op 0)
    public let param: Int  // decoded parameter (signed, as the oracle prints `(int)(int16)`)
    public let delay: Int, sp: Int, fp: Int, returnValue: Int, current: Int

    /// Byte-for-byte the oracle's `fprintf` format (`pc=… op=… param=… delay=… SP=… FP=… return=… current=0x…`).
    public var oracleFormat: String {
        "pc=\(pc) op=\(op) param=\(param) delay=\(delay) SP=\(sp) FP=\(fp) return=\(returnValue) "
            + "current=0x" + String(format: "%04x", current)
    }

    /// Decode the next opcode of `engine` **without** executing it — the exact decode `DefaultScriptInterpreter`
    /// does at the top of `run` (opcode = `(current>>8)&0x1F`; the 0x8000/0x4000/0x2000 parameter flags),
    /// paired with the engine's pre-execution `delay`/`SP`/`FP`/`returnValue`. Returns nil at a malformed PC.
    public static func decode(_ engine: ScriptEngine, info: ScriptInfo) -> ScriptTraceLine? {
        let program = info.program
        let pc = Int(engine.scriptPC)
        guard pc < program.count else { return nil }
        let current = program[pc]

        var op = Int((current >> 8) & 0x1F)
        var param = 0
        if current & 0x8000 != 0 {
            op = 0; param = Int(current & 0x7FFF)  // 13-bit GOTO
        } else if current & 0x4000 != 0 {
            param = Int(Int16(Int8(bitPattern: UInt8(current & 0xFF))))  // sign-extended int8
        } else if current & 0x2000 != 0, pc + 1 < program.count {
            param = Int(Int16(bitPattern: program[pc + 1]))  // the next word
        }

        return ScriptTraceLine(
            pc: pc,
            op: op,
            param: param,
            delay: Int(engine.delay),
            sp: Int(engine.stackPointer),
            fp: Int(engine.framePointer),
            returnValue: Int(engine.returnValue),
            current: Int(current)
        )
    }
}

/// A per-opcode trace sink for one structure (matched by `o.index`), mirroring OpenDUNE's
/// `g_parityScriptTraceStructureIndex`. Injected into `Simulation` for the Tier-2a structure decision-trace
/// harness; nil in normal operation (zero overhead). Reference type + `Mutex` so a value-type `Simulation`
/// run can accumulate lines and the test reads them after.
public final class StructureScriptTracer: Sendable {
    public let structureIndex: UInt16
    private let buffer = Mutex<[String]>([])

    public init(structureIndex: UInt16) { self.structureIndex = structureIndex }

    func record(_ line: String) { buffer.withLock { $0.append(line) } }

    /// The captured trace, one oracle-format line per executed opcode, in order.
    public var lines: [String] { buffer.withLock { $0 } }
}
