import DuneIIContracts
import DuneIIWorld
import Testing

@testable import DuneIISimulation

/// Coverage for `Unit_SetAction` (`UnitActions`, OpenDUNE `unit.c:497`) — the action switch that
/// (re)loads a unit's EMC script. Uses a synthetic `ScriptInfo` (per-type offsets) so the script-load
/// effect is observable without a real `UNIT.EMC`.
@Suite("Unit_SetAction")
struct UnitActionsTests {
    let actions = UnitActions()
    // offsets[typeID] = typeID, so loading a script for type T parks the PC at T.
    let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })
    private func u(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }

    private func stateWithUnit(_ type: UnitType) -> (GameState, Int) {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: u(type), houseID: 0)!  // tank = type 9
        return (s, slot)
    }

    @Test("switchType 0 with no destination switches immediately and loads the script")
    func switchType0NoDestination() {
        var (s, slot) = stateWithUnit(.tank)
        actions.setAction(slot: slot, action: u2(.move), scriptInfo: info, in: &s)  // Move = 1, switchType 0
        #expect(s.units[slot].actionID == 1)
        #expect(s.units[slot].nextActionID == 0xFF)
        #expect(s.units[slot].o.script.variables[0] == 1)
        #expect(s.units[slot].o.script.scriptPC == 9)  // offsets[tank]
        #expect(s.units[slot].o.script.framePointer == 17)  // Script_Reset applied
        #expect(actions.interpreter.isLoaded(s.units[slot].o.script))
    }

    @Test("switchType 0 with a destination queues into nextActionID without loading")
    func switchType0WithDestination() {
        var (s, slot) = stateWithUnit(.tank)
        s.units[slot].currentDestination = Tile32.unpack(30 * 64 + 30)
        s.units[slot].actionID = u2(.guard_)
        actions.setAction(slot: slot, action: u2(.move), scriptInfo: info, in: &s)
        #expect(s.units[slot].nextActionID == 1)  // queued
        #expect(s.units[slot].actionID == u2(.guard_))  // unchanged
        #expect(!actions.interpreter.isLoaded(s.units[slot].o.script))  // no script loaded
    }

    @Test("switchType 1 (die) switches immediately")
    func switchType1() {
        var (s, slot) = stateWithUnit(.tank)
        s.units[slot].actionID = u2(.guard_)
        actions.setAction(slot: slot, action: u2(.die), scriptInfo: info, in: &s)  // Die = 10, switchType 1
        #expect(s.units[slot].actionID == 10)
        #expect(s.units[slot].o.script.scriptPC == 9)
        #expect(s.units[slot].o.script.variables[0] == 10)
    }

    @Test("a dying/destructing unit ignores setAction; ACTION_INVALID is a no-op")
    func earlyReturns() {
        var (s, slot) = stateWithUnit(.tank)
        s.units[slot].actionID = u2(.destruct)
        actions.setAction(slot: slot, action: u2(.move), scriptInfo: info, in: &s)
        #expect(s.units[slot].actionID == u2(.destruct))  // unchanged (already self-destructing)

        s.units[slot].actionID = u2(.guard_)
        actions.setAction(slot: slot, action: 0xFF, scriptInfo: info, in: &s)  // ACTION_INVALID
        #expect(s.units[slot].actionID == u2(.guard_))  // unchanged
    }

    private func u2(_ a: ActionType) -> UInt8 { UInt8(a.rawValue) }
}
