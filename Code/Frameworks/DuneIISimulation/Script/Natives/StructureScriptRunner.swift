import DuneIIContracts
import DuneIIWorld

/// Runs a structure's EMC script: the op-14 dispatch glue (`g_scriptFunctionsStructure`) plus the per-tick
/// run loop. The structure analog of `UnitScriptRunner` — same VM (`ScriptInterpreter`), different native
/// table + program (the bridged `BUILD.EMC`).
///
/// Shares the unit runner's `UnitCombat` so the structure death natives (`Explode`/`Destroy`) reach the
/// same `Map_MakeExplosion` + `Unit_Create` + `Unit_SetAction` layer (and the unit `ScriptInfo` for the
/// soldiers they spawn). Not-yet-ported natives return `nil` from `dispatch`, halting the script cleanly
/// (the VM nulls the PC) — a structure runs as far as the natives it reaches are implemented, then freezes.
public struct StructureScriptRunner: Sendable {
    public let interpreter: any ScriptInterpreter
    public let scriptInfo: ScriptInfo
    let general: GeneralScriptFunctions
    let structure: StructureScriptFunctions
    /// Optional Tier-2a decision-trace sink (one structure by `o.index`); nil in normal operation.
    let tracer: StructureScriptTracer?

    init(scriptInfo: ScriptInfo, combat: UnitCombat, interpreter: any ScriptInterpreter,
         tracer: StructureScriptTracer? = nil) {
        self.interpreter = interpreter
        self.scriptInfo = scriptInfo
        self.general = GeneralScriptFunctions()
        self.structure = StructureScriptFunctions(combat: combat)
        self.tracer = tracer
    }

    /// op-14 dispatch for a structure script — route the function `index` to its native, peeking arguments
    /// off `engine`'s stack. The running structure is `state.structures[slot]`. `nil` ⇒ a function not yet
    /// ported (the index table is `g_scriptFunctionsStructure`).
    func dispatch(_ index: Int, engine: inout ScriptEngine, state: inout GameState, slot: Int) -> UInt16? {
        switch index {
            case 0x00: let d = general.delay(ticks: engine.peek(1)); engine.delay = d; return d
            case 0x01, 0x0C, 0x10, 0x11, 0x12, 0x13, 0x14, 0x18: return general.noOperation()
            case 0x02: return structure.unknown0A81(slot: slot, in: &state)
            case 0x03: return structure.findUnitByType(slot: slot, type: engine.peek(1), in: &state)
            case 0x04: return structure.setState(slot: slot, state: Int16(bitPattern: engine.peek(1)), in: &state)
            case 0x05: return general.noOperation()   // Script_Structure_DisplayText — GUI (SEAM)
            case 0x06: return structure.unknown11B9(encoded: engine.peek(1), in: &state)
            case 0x07: return structure.unloadLinkedUnit(slot: slot, in: &state)
            case 0x08: return structure.findTargetUnit(slot: slot, range: engine.peek(1), in: &state)
            case 0x09: return structure.rotateTurret(slot: slot, encoded: engine.peek(1), in: &state)
            case 0x0A: return structure.getDirection(slot: slot, encoded: engine.peek(1), in: state)
            case 0x0B: return structure.fire(slot: slot, in: &state)
            case 0x0D: return structure.getState(slot: slot, in: state)
            case 0x15: return structure.refineSpice(slot: slot, in: &state)
            case 0x0E: state.emitSound(Int(engine.peek(1)), at: state.structures[slot].o.position); return 0   // Script_Structure_VoicePlay
            case 0x0F: return structure.removeFogAroundTile(slot: slot, in: &state)
            case 0x16: return structure.explode(slot: slot, in: &state)
            case 0x17: return structure.destroy(slot: slot, in: &state)
            default:   return nil   // all BUILD.EMC natives ported; an unused slot would clean-halt
        }
    }

    /// Run a fixed batch of `budget` opcodes (`GameLoop_Structure` runs exactly 3), stopping early only on a
    /// script error / unported native (`Script_Run` → false) or when the structure frees itself mid-run.
    /// Returns the opcode count executed — the caller uses `< budget` as OpenDUNE's `i != 3` abort signal.
    ///
    /// Unlike the unit runner, the loop does **not** stop on `delay`: OpenDUNE's structure loop is a plain
    /// `for (i = 0; i < 3; i++)` with no delay guard, so a `General_Delay` set mid-batch still lets the
    /// remaining opcodes of the batch run; the delay only takes effect on the *next* script-tick (the
    /// caller's pre-run `delay--` guard). `Destroy` calls `Structure_Remove`, which frees the slot and
    /// resets its script — mirroring OpenDUNE, the next iteration breaks (the freed script is not loaded),
    /// and the engine write-back is guarded on the slot still being `used`.
    @discardableResult
    func run(slot: Int, in state: inout GameState, budget: Int) -> Int {
        var engine = state.structures[slot].o.script
        var executed = 0
        while executed < budget && interpreter.isLoaded(engine) {
            // Tier-2a: emit the pre-execution decision-trace line for the watched structure (matches the
            // oracle's per-`Script_Run` `--parity-script-trace` point).
            if let tracer, state.structures[slot].o.index == tracer.structureIndex,
               let line = ScriptTraceLine.decode(engine, info: scriptInfo) {
                tracer.record(line.oracleFormat)
            }
            let ok = interpreter.run(&engine, info: scriptInfo) { index, eng in
                // The VM runs on a *copy* of the engine, but a native may mutate this structure's **live**
                // script through `state` (e.g. `Object_Script_Variable4_Clear` in the refinery's deploy
                // path). Sync VM→state before the call; if a native rewrote the live script, adopt it back —
                // else keep the VM engine (the delay native sets `eng.delay`, never `state`). Without this
                // the copy clobbers the native's change on write-back and the refinery never deploys its
                // harvester. OpenDUNE shares one pointer. See insight `sim-script-vm-engine-copy`.
                let before = eng
                state.structures[slot].o.script = eng
                let result = dispatch(index, engine: &eng, state: &state, slot: slot)
                if state.structures[slot].o.flags.contains(.used), state.structures[slot].o.script != before {
                    eng = state.structures[slot].o.script
                }
                return result
            }
            executed += 1
            if !ok { break }
            if !state.structures[slot].o.flags.contains(.used) { break }   // freed by Destroy
        }
        if state.structures[slot].o.flags.contains(.used) {
            state.structures[slot].o.script = engine
        }
        return executed
    }
}
