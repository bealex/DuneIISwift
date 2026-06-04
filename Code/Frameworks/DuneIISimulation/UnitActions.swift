import DuneIIContracts
import DuneIIWorld

/// Unit action/script orchestration that needs the EMC VM — `Unit_SetAction` and friends (`unit.c`).
/// Holds the injected `ScriptInterpreter` (the replaceable VM); the unit-category `ScriptInfo` (the
/// loaded `UNIT.EMC` program) is passed per call. Kept apart from the pure `UnitScriptFunctions` natives
/// because it (re)loads scripts.
public struct UnitActions: Sendable {
    public let interpreter: any ScriptInterpreter

    public init(interpreter: any ScriptInterpreter = DefaultScriptInterpreter()) {
        self.interpreter = interpreter
    }

    /// `Unit_SetAction` (`unit.c:497`): switch a unit to `action`, (re)loading its EMC script for the
    /// unit's own type. A unit already dying/self-destructing, or `ACTION_INVALID` (0xFF), is left
    /// untouched. By `switchType`: 0 queues the action behind an in-progress move (`nextActionID`) when
    /// the unit has a destination, else falls through to an immediate switch; 1 switches immediately
    /// (reset script, `variables[0] = action`, `Script_Load`); 2 loads the action as a subroutine.
    ///
    /// The unit's script `engine` is passed separately (not read out of `state.units[slot].o.script`):
    /// during a VM run the live engine is a copy held by the runner, so the script (re)load must target
    /// it, while the unit's other fields live in `state`. Standalone callers use the `slot`-only overload.
    public func setAction(
        slot: Int,
        action: UInt8,
        scriptInfo: ScriptInfo,
        engine: inout ScriptEngine,
        in state: inout GameState
    ) {
        let current = state.units[slot].actionID
        if current == UInt8(ActionType.destruct.rawValue)
                || current == UInt8(ActionType.die.rawValue)
                || action == 0xFF {
            return
        }
        guard let actionType = ActionType(rawValue: Int(action)) else { return }

        let type = Int(state.units[slot].o.type)

        switch ActionInfo[actionType].switchType {
            case 0:
                let dest = state.units[slot].currentDestination
                if dest.x != 0 || dest.y != 0 {
                    state.units[slot].nextActionID = action
                    return
                }
                fallthrough
            case 1:
                state.units[slot].actionID = action
                state.units[slot].nextActionID = 0xFF
                state.units[slot].currentDestination = Tile32(x: 0, y: 0)
                engine.delay = 0
                engine.reset()
                engine.variables[0] = UInt16(action)
                interpreter.load(&engine, info: scriptInfo, typeID: type)
            case 2:
                engine.variables[0] = UInt16(action)
                interpreter.loadAsSubroutine(&engine, info: scriptInfo, typeID: type)
            default:
                break
        }
    }

    /// Standalone `Unit_SetAction` for callers outside a script run — the unit's own `o.script` is the
    /// engine. Copies it out and back around the engine-separated core to avoid overlapping `inout`
    /// access to `state`.
    public func setAction(slot: Int, action: UInt8, scriptInfo: ScriptInfo, in state: inout GameState) {
        var engine = state.units[slot].o.script
        setAction(slot: slot, action: action, scriptInfo: scriptInfo, engine: &engine, in: &state)
        state.units[slot].o.script = engine
    }
}
