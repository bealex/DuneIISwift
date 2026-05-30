import DuneIIContracts
import DuneIIWorld

/// Runs a team's EMC script: the op-14 dispatch glue (`g_scriptFunctionsTeam`) plus the per-loop run.
/// The team analog of `UnitScriptRunner`/`StructureScriptRunner` — same VM (`ScriptInterpreter`), different
/// native table + program (the bridged `TEAM.EMC`). `GameLoop_Team` runs exactly one `Script_Run` per team
/// per loop fire (no 3-opcode batch), so `runOne` runs a single opcode and writes the engine back.
///
/// The full `g_scriptFunctionsTeam` table is now live (getters + recruit/target + the order-issuing
/// natives + the `Load`/`Load2` script switch). The order natives (`0x05`/`0x07`) need the unit-action
/// layer, so they clean-halt (return `nil`) when the runner has no `unit` — and per the 1.07 loop quirk a
/// clean-halt aborts the remaining teams this fire.
public struct TeamScriptRunner: Sendable {
    public let interpreter: any ScriptInterpreter
    public let scriptInfo: ScriptInfo
    let general: GeneralScriptFunctions
    let team: TeamScriptFunctions
    /// The unit-script runner, when present — the team natives reuse its `TargetFinder` (and, in a follow-up
    /// slice, its action layer) to reach into units. Absent ⇒ those natives clean-halt.
    let unit: UnitScriptRunner?

    init(scriptInfo: ScriptInfo, interpreter: any ScriptInterpreter, unit: UnitScriptRunner? = nil) {
        self.interpreter = interpreter
        self.scriptInfo = scriptInfo
        self.general = GeneralScriptFunctions()
        self.team = TeamScriptFunctions()
        self.unit = unit
    }

    /// op-14 dispatch for a team script — route the function `index` to its native (`g_scriptFunctionsTeam`).
    /// The running team is `state.teams[slot]`. `nil` ⇒ a function not yet ported (clean-halt).
    func dispatch(_ index: Int, engine: inout ScriptEngine, state: inout GameState, slot: Int) -> UInt16? {
        switch index {
            case 0x00: let d = general.delay(ticks: engine.peek(1)); engine.delay = d; return d
            case 0x01, 0x0B: return general.noOperation()   // DisplayText / DisplayModalMessage — GUI (SEAM)
            case 0x02: return team.getMembers(slot: slot, in: state)
            case 0x03: return team.addClosestUnit(slot: slot, in: &state)
            case 0x04: return team.getAverageDistance(slot: slot, in: &state)
            case 0x06:
                guard let targets = unit?.targets else { return nil }
                return team.findBestTarget(slot: slot, targets: targets, in: &state)
            case 0x05:
                guard let u = unit else { return nil }   // needs the unit-action layer
                return team.moveOrGuardMembers(slot: slot, distance: engine.peek(1), unitScript: u.scriptInfo,
                                               actions: u.actions, unitFuncs: u.unit, in: &state)
            case 0x07:
                guard let u = unit else { return nil }
                return team.issueAttackOrders(slot: slot, unitScript: u.scriptInfo, actions: u.actions,
                                              unitFuncs: u.unit, in: &state)
            case 0x08: return team.load(slot: slot, type: engine.peek(1), interpreter: interpreter,
                                        scriptInfo: scriptInfo, engine: &engine, in: &state)
            case 0x09: return team.load2(slot: slot, interpreter: interpreter, scriptInfo: scriptInfo,
                                         engine: &engine, in: &state)
            case 0x0A: return general.delayRandom(maxTicks: engine.peek(1), in: &state)
            case 0x0C: return team.getVariable6(slot: slot, in: state)
            case 0x0D: return team.getTarget(slot: slot, in: state)
            case 0x0E: return general.noOperation()
            default:   return nil
        }
    }

    /// Run a single opcode (`GameLoop_Team` runs `Script_Run` once per team per fire). Returns the VM's
    /// `ok` — `false` on a clean-halt / script error, which the caller uses as the 1.07 abort signal.
    @discardableResult
    func runOne(slot: Int, in state: inout GameState) -> Bool {
        var engine = state.teams[slot].script
        let ok = interpreter.run(&engine, info: scriptInfo) { index, eng in
            dispatch(index, engine: &eng, state: &state, slot: slot)
        }
        state.teams[slot].script = engine
        return ok
    }
}
