import DuneIIContracts
import DuneIIWorld

/// Runs a unit's EMC script: the op-14 dispatch glue (maps a function index to a ported native, reading
/// its arguments off the engine stack) plus the per-call run loop. This is the layer that connects the
/// category-agnostic VM (`ScriptInterpreter`) to the clean `Script_*` native functions.
///
/// Not-yet-ported natives return `nil` from `dispatch`, which halts the script cleanly (the VM nulls the
/// PC) — so a script runs as far as the natives it reaches are implemented, then the unit freezes. The
/// gap is loud (the unit visibly stops) rather than a silent no-op or a timing-skewing per-tick suspend.
public struct UnitScriptRunner: Sendable {
    public let interpreter: any ScriptInterpreter
    public let scriptInfo: ScriptInfo
    let general: GeneralScriptFunctions
    let unit: UnitScriptFunctions
    let actions: UnitActions
    public let movement: UnitMovement
    let targets: TargetFinder

    public init(scriptInfo: ScriptInfo,
                interpreter: any ScriptInterpreter = DefaultScriptInterpreter(),
                unitPrimitives: any UnitPrimitives = DefaultUnitPrimitives(),
                mapPrimitives: any MapPrimitives = DefaultMapPrimitives(),
                housePrimitives: any HousePrimitives = DefaultHousePrimitives()) {
        self.interpreter = interpreter
        self.scriptInfo = scriptInfo
        self.general = GeneralScriptFunctions()
        self.unit = UnitScriptFunctions(unitPrimitives: unitPrimitives)
        self.actions = UnitActions(interpreter: interpreter)
        self.movement = UnitMovement(scriptInfo: scriptInfo, interpreter: interpreter,
                                     unitPrimitives: unitPrimitives, mapPrimitives: mapPrimitives,
                                     housePrimitives: housePrimitives)
        self.targets = TargetFinder(map: mapPrimitives, house: housePrimitives)
    }

    /// op-14 dispatch for a unit script — route the function `index` to its native, peeking arguments
    /// off `engine`'s stack (`STACK_PEEK`). The running unit is `state.units[slot]`. `nil` ⇒ a function
    /// not yet ported (the index table is `g_scriptFunctionsUnit`).
    func dispatch(_ index: Int, engine: inout ScriptEngine, state: inout GameState, slot: Int) -> UInt16? {
        let u = state.units[slot]
        switch index {
            case 0x00: return unit.getInfo(slot: slot, field: engine.peek(1), in: &state)
            case 0x01:  // Script_Unit_SetAction (+ the player-harvest guard)
                let action = engine.peek(1)
                if u.o.houseID == state.playerHouseID
                    && action == UInt16(ActionType.harvest.rawValue)
                    && u.nextActionID != 0xFF { return 0 }
                actions.setAction(slot: slot, action: UInt8(truncatingIfNeeded: action),
                                  scriptInfo: scriptInfo, engine: &engine, in: &state)
                return 0
            case 0x03: return general.getDistanceToTile(from: u.o.position, encoded: engine.peek(1), in: state)
            case 0x05: return unit.setDestination(slot: slot, encoded: engine.peek(1), in: &state)
            case 0x06: return unit.getOrientation(u, encoded: engine.peek(1), in: state)
            case 0x07: return unit.setOrientation(slot: slot, orientation: Int8(truncatingIfNeeded: engine.peek(1)), in: &state)
            case 0x08: return unit.fire(slot: slot, in: &state)
            case 0x0C: return movement.calculateRoute(slot: slot, encoded: engine.peek(1), engine: &engine, in: &state)
            case 0x0D: return general.isEnemy(currentHouseID: state.unitHouseID(u), encoded: engine.peek(1), in: state)
            case 0x10: let d = general.delay(ticks: engine.peek(1)); engine.delay = d; return d
            case 0x11: return general.isFriendly(currentHouseID: state.unitHouseID(u), encoded: engine.peek(1), in: state)
            case 0x15, 0x2B, 0x34, 0x35, 0x39, 0x3F: return general.noOperation()
            case 0x17: return general.randomRange(min: engine.peek(1), max: engine.peek(2), in: &state)
            case 0x19: return unit.setDestinationDirect(slot: slot, encoded: engine.peek(1), in: &state)
            case 0x1A: return unit.stop(slot: slot, in: &state)
            case 0x1B: return unit.setSpeed(slot: slot, requestedSpeed: engine.peek(1), in: &state)
            case 0x1C: return targets.findBestTargetEncoded(slot: slot, mode: engine.peek(1), in: &state)
            case 0x1F: return unit.isInTransport(u)
            case 0x20: return unit.getAmount(u, in: state)
            case 0x24: return unit.unknown2552(slot: slot, in: &state)
            case 0x25: return unit.findStructure(slot: slot, type: engine.peek(1), in: state)
            case 0x28: return unit.removeFog(slot: slot, in: &state)
            case 0x2C: return general.getLinkedUnitType(linkedID: u.o.linkedID, in: state)
            case 0x2D: return general.getIndexType(encoded: engine.peek(1), in: state)
            case 0x2E: return general.decodeIndex(encoded: engine.peek(1), in: state)
            case 0x30: return unit.getRandomTile(slot: slot, encoded: engine.peek(1), in: &state)
            case 0x31: return unit.idleAction(slot: slot, in: &state)
            case 0x32: return general.unitCount(houseID: u.o.houseID, type: engine.peek(1), in: state)
            case 0x38: return general.getOrientation(encoded: engine.peek(1), in: state)
            case 0x3A: return unit.setTarget(slot: slot, target: engine.peek(1), in: &state)
            case 0x3C: let d = general.delayRandom(maxTicks: engine.peek(1), in: &state); engine.delay = d; return d
            case 0x3D: return unit.rotate(slot: slot, in: &state)
            case 0x3E: return general.getDistanceToObject(from: u.o.position, encoded: engine.peek(1), in: state)
            default:   return nil   // not yet ported
        }
    }

    /// Run the unit's script for up to `budget` opcodes, stopping early when it suspends (`delay`), halts,
    /// or hits an unported native. Returns the opcode count executed. The live engine is copied out so
    /// the dispatch can mutate `state` (including the unit) without overlapping `inout` access to it.
    @discardableResult
    public func run(slot: Int, in state: inout GameState, budget: Int) -> Int {
        var engine = state.units[slot].o.script
        var executed = 0
        while executed < budget && engine.delay == 0 && interpreter.isLoaded(engine) {
            let ok = interpreter.run(&engine, info: scriptInfo) { index, eng in
                dispatch(index, engine: &eng, state: &state, slot: slot)
            }
            executed += 1
            if !ok { break }
        }
        state.units[slot].o.script = engine
        return executed
    }
}
