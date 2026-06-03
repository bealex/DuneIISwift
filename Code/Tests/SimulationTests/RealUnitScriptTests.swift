import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIISimulation

/// Real-data integration: bridge the committed `UNIT.EMC` into a `ScriptInfo`, switch a unit to an
/// action (which loads its real script), and run it under the VM + dispatch. This exercises the whole
/// chain on actual game bytecode — `Emc.Program` → `ScriptInfo` → `Unit_SetAction` (`Script_Load`) →
/// `Script_Run` → the native dispatch — and confirms the runner decodes real opcodes and halts
/// gracefully when it reaches a not-yet-ported native. (The exact per-opcode trace vs the oracle's
/// `g_parityScriptTrace` is a later step, once enough natives exist to run a full action.)
@Suite("Real UNIT.EMC under the VM")
struct RealUnitScriptTests {
    @Test("UNIT.EMC bridges to ScriptInfo and a unit's real script runs under the VM")
    func realScriptRuns() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/SimulationTests → repo root
        let url = repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")
        guard let data = try? Data(contentsOf: url) else { return }  // short-circuit if absent

        let info = ScriptInfo(try Emc.Program(data))
        #expect(!info.program.isEmpty)
        #expect(info.offsets.count >= 10)  // enough entries to cover the common unit types

        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(20 * 64 + 20)

        // Switch to an action ⇒ loads the unit type's real script at its ORDR offset.
        let runner = UnitScriptRunner(scriptInfo: info)
        UnitActions().setAction(slot: slot, action: UInt8(ActionType.guard_.rawValue), scriptInfo: info, in: &s)
        #expect(runner.interpreter.isLoaded(s.units[slot].o.script))
        #expect(s.units[slot].o.script.scriptPC == info.offsets[Int(UnitType.tank.rawValue)])
        #expect(s.units[slot].o.script.variables[0] == UInt16(ActionType.guard_.rawValue))

        // Run the real bytecode: executes the ported prefix, then suspends (delay) or halts at the first
        // unported native. Either way it must decode at least one real opcode without trapping.
        let executed = runner.run(slot: slot, in: &s, budget: 50)
        #expect(executed >= 1)
    }
}
