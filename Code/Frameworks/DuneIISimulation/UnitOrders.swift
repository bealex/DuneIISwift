import DuneIIContracts
import DuneIIWorld

/// The player-order (input → sim) path: turns a `Command` into the same unit order the original game
/// issues from a viewport click (`GUI_Widget_Viewport_Click`, `src/gui/viewport.c`) — clear the unit's
/// targets, resolve the clicked tile, `Unit_SetAction`, then `Unit_SetDestination` (move) or
/// `Unit_SetTarget` (attack). Holds the pieces those compose: the script `interpreter`/`scriptInfo` (via
/// `UnitActions`), the `UnitPrimitives` (for `Unit_IsValidMovementIntoStructure`), and the
/// `MapPrimitives` (for `Map_GetLandscapeType`).
public struct UnitOrders: Sendable {
    public let actions: UnitActions
    public let primitives: any UnitPrimitives
    public let map: any MapPrimitives
    public let scriptInfo: ScriptInfo

    public init(scriptInfo: ScriptInfo,
                interpreter: any ScriptInterpreter = DefaultScriptInterpreter(),
                primitives: any UnitPrimitives = DefaultUnitPrimitives(),
                map: any MapPrimitives = DefaultMapPrimitives()) {
        self.scriptInfo = scriptInfo
        self.actions = UnitActions(interpreter: interpreter)
        self.primitives = primitives
        self.map = map
    }

    /// Apply a `Command` (the input seam) to the unit it names.
    public func apply(_ command: Command, in state: inout GameState) {
        switch command {
            case let .move(unit, tile):   order(slot: Int(unit), action: .move, targetPacked: tile, in: &state)
            case let .attack(unit, tile): order(slot: Int(unit), action: .attack, targetPacked: tile, in: &state)
            case let .stop(unit):         stop(slot: Int(unit), in: &state)
        }
    }

    /// Stop the unit: clear its move/attack targets + route and set it to GUARD in place (the original's
    /// viewport "stop"/deselect-to-guard behaviour).
    public func stop(slot: Int, in state: inout GameState) {
        guard slot >= 0, slot < state.units.count else { return }
        state.objectScriptVariable4Clear(.unit(slot))
        state.units[slot].targetAttack = 0
        state.units[slot].targetMove = 0
        state.units[slot].route[0] = 0xFF
        actions.setAction(slot: slot, action: UInt8(ActionType.guard_.rawValue), scriptInfo: scriptInfo, in: &state)
    }

    /// The viewport-click order: clear the unit's existing targets, resolve the target tile (for an
    /// attack, snap to a nearby object), set the action, then the destination/target.
    public func order(slot: Int, action: ActionType, targetPacked: UInt16, in state: inout GameState) {
        state.objectScriptVariable4Clear(.unit(slot))
        state.units[slot].targetAttack = 0
        state.units[slot].targetMove = 0
        state.units[slot].route[0] = 0xFF

        let encoded: UInt16
        if action == .move || action == .harvest {
            encoded = state.indexEncode(targetPacked, type: .tile)
        } else {
            encoded = state.indexEncode(findTargetAround(targetPacked, in: state), type: .tile)
        }

        actions.setAction(slot: slot, action: UInt8(action.rawValue), scriptInfo: scriptInfo, in: &state)

        switch action {
            case .move:    setDestination(slot: slot, encoded, in: &state)
            case .harvest: state.units[slot].targetMove = encoded
            default:       setTarget(slot: slot, encoded, in: &state)
        }
    }

    /// `Unit_SetDestination` (`unit.c:701`): set `targetMove`, resolving a tile that holds a unit/structure
    /// to that object, and linking script-var-4 when moving into a friendly enterable structure. Delegates
    /// to the single home of the primitive (`UnitScriptFunctions.unitSetDestination`), which the script
    /// native `Script_Unit_SetDestination` also uses.
    public func setDestination(slot: Int, _ destination0: UInt16, in state: inout GameState) {
        UnitScriptFunctions(unitPrimitives: primitives).unitSetDestination(slot: slot, destination0, in: &state)
    }

    /// `Unit_SetTarget` (`unit.c:621`): set `targetAttack`, resolving a tile to the object on it; targeting
    /// self becomes a tile target; a turretless unit also moves to the target. Delegates to the single home
    /// of the primitive (`UnitScriptFunctions.unitSetTarget`), which `Script_Unit_Fire` also uses.
    public func setTarget(slot: Int, _ encoded0: UInt16, in state: inout GameState) {
        UnitScriptFunctions(unitPrimitives: primitives).unitSetTarget(slot: slot, encoded0, in: &state)
    }

    /// `Unit_FindTargetAround` (`unit.c`): the tile of a unit on or adjacent to `packed` (preferring a
    /// structure / bloom field at `packed` itself), else `packed`.
    public func findTargetAround(_ packed: UInt16, in state: GameState) -> UInt16 {
        let around = [0, -1, 1, -64, 64, -65, -63, 65, 63]
        if state.structureGetByPackedTile(packed) != nil { return packed }
        if map.landscapeType(state.map[Int(packed)], tileIDs: state.tileIDs) == .bloomField { return packed }
        for offset in around {
            let p = Int(packed) + offset
            guard p >= 0, p < state.map.count else { continue }
            if let u = state.unitGetByPackedTile(UInt16(p)) { return state.units[u].o.position.packed }
        }
        return packed
    }
}
