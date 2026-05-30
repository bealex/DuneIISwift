import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// Integration coverage for the op-14 dispatch glue + the script run loop (`UnitScriptRunner`) — the
/// layer joining the VM to the clean natives. The natives themselves are unit-tested elsewhere; here we
/// check routing (each index reaches the right native with its stack args) and an end-to-end run.
@Suite("Unit script dispatch + runner")
struct UnitScriptRunnerTests {
    private func ut(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }

    // offsets[typeID] = typeID, so a script load for type T parks the PC at T.
    let typeOffsets = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func setup(_ type: UnitType, scriptInfo: ScriptInfo) -> (GameState, Int, UnitScriptRunner) {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: ut(type), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(20 * 64 + 20)
        return (s, slot, UnitScriptRunner(scriptInfo: scriptInfo))
    }

    /// An engine whose stack is arranged so `peek(i+1) == values[i]`.
    private func engine(peeking values: [UInt16]) -> ScriptEngine {
        var e = ScriptEngine()
        let n = values.count
        e.stackPointer = UInt8(15 - n)
        for (i, v) in values.enumerated() { e.stack[15 - n + i] = v }
        return e
    }

    // Bytecode word builders (inline-byte parameter form).
    private func inlineOp(_ op: Int, _ byte: Int) -> UInt16 { UInt16(0x4000 | (op << 8) | (byte & 0xFF)) }

    @Test("dispatch routes each function index to the right native")
    func dispatchRouting() {
        var (s, slot, runner) = setup(.tank, scriptInfo: typeOffsets)

        var e0 = engine(peeking: [0x07])   // GetInfo field 7 = type
        #expect(runner.dispatch(0x00, engine: &e0, state: &s, slot: slot) == UInt16(s.units[slot].o.type))

        var e1 = engine(peeking: [50])     // Delay 50 → 10 and sets engine.delay
        #expect(runner.dispatch(0x10, engine: &e1, state: &s, slot: slot) == 10)
        #expect(e1.delay == 10)

        var e2 = engine(peeking: [200])    // SetSpeed 200 → the unit's resulting speed
        #expect(runner.dispatch(0x1B, engine: &e2, state: &s, slot: slot) == UInt16(s.units[slot].speed))

        var e3 = engine(peeking: [])       // NoOperation
        #expect(runner.dispatch(0x15, engine: &e3, state: &s, slot: slot) == 0)

        #expect(runner.dispatch(0x14, engine: &e3, state: &s, slot: slot) == nil)   // TransportDeliver (carryall): not yet ported
    }

    @Test("dispatch op-01 SetAction (re)loads the script into the passed engine")
    func dispatchSetAction() {
        var (s, slot, runner) = setup(.tank, scriptInfo: typeOffsets)
        var e = engine(peeking: [UInt16(ActionType.move.rawValue)])   // Move = 1 (switchType 0)
        _ = runner.dispatch(0x01, engine: &e, state: &s, slot: slot)
        #expect(s.units[slot].actionID == 1)
        #expect(e.scriptPC == 9)   // offsets[tank = 9], loaded into the engine we passed
    }

    @Test("run executes a script end-to-end through the VM + dispatch, stopping when it suspends")
    func endToEnd() {
        // Program: PUSH 50; FUNCTION 0x10 (Delay) ⇒ engine.delay = 10, returnValue = 10.
        let prog = [inlineOp(3, 50), inlineOp(14, 0x10)]
        let info = ScriptInfo(program: prog, offsets: [0])
        var (s, slot, runner) = setup(.tank, scriptInfo: info)
        runner.interpreter.load(&s.units[slot].o.script, info: info, typeID: 0)

        let executed = runner.run(slot: slot, in: &s, budget: 10)
        #expect(executed == 2)                          // PUSH + FUNCTION, then suspended by the delay
        #expect(s.units[slot].o.script.delay == 10)
        #expect(s.units[slot].o.script.returnValue == 10)
        #expect(s.units[slot].o.script.scriptPC == 2)   // stopped right after the Delay opcode
    }

    @Test("run halts cleanly on an unported native (PC nulled) and writes the engine back")
    func runHaltsOnUnported() {
        // Program: FUNCTION 0x14 (TransportDeliver) — not yet ported ⇒ dispatch returns nil ⇒ the script
        // halts cleanly: the run stops after the one opcode and the PC is nulled so it stays stopped.
        let prog = [inlineOp(14, 0x14)]
        let info = ScriptInfo(program: prog, offsets: [0])
        var (s, slot, runner) = setup(.tank, scriptInfo: info)
        runner.interpreter.load(&s.units[slot].o.script, info: info, typeID: 0)
        let executed = runner.run(slot: slot, in: &s, budget: 10)
        #expect(executed == 1)
        #expect(!runner.interpreter.isLoaded(s.units[slot].o.script))   // halted, not merely suspended
        #expect(runner.run(slot: slot, in: &s, budget: 10) == 0)        // stays stopped
    }
}
