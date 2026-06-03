import DuneIIWorld
import Testing

@testable import DuneIISimulation

/// VM-core coverage for the EMC interpreter (`DefaultScriptInterpreter` = OpenDUNE `Script_Run` + the
/// stack ops + load/reset). Synthetic bytecode programs with hand-derived expected results, one per
/// opcode / parameter-encoding / error path. The per-script decision-trace golden against the oracle
/// lands once the native function tables exist and a real script can run end-to-end.
@Suite("EMC script VM core")
struct ScriptVMTests {
    let vm = DefaultScriptInterpreter()

    // Bytecode word builders. opcode occupies bits 8–12; flags 0x8000 (GOTO), 0x4000 (inline signed
    // byte), 0x2000 (parameter in the next word).
    func inlineOp(_ op: Int, _ byte: Int) -> UInt16 { UInt16(0x4000 | (op << 8) | (byte & 0xFF)) }
    func bareOp(_ op: Int) -> UInt16 { UInt16(op << 8) }  // parameter = 0
    func goto(_ addr: Int) -> UInt16 { UInt16(0x8000 | addr) }

    // Opcode numbers used below.
    let PUSH = 3, SETRV = 1, POP_RET = 8, BINARY = 17, UNARY = 16, JUMP_NE = 15, FUNCTION = 14, RETURN = 18

    /// Load `program` at type 0 and run `steps` opcodes (no native functions). Returns the engine.
    func runProgram(
        _ program: [UInt16],
        steps: Int,
        callFunction: @escaping (Int, inout ScriptEngine) -> UInt16? = { _, _ in nil }
    ) -> ScriptEngine {
        var engine = ScriptEngine()
        let info = ScriptInfo(program: program, offsets: [ 0 ])
        vm.load(&engine, info: info, typeID: 0)
        for _ in 0 ..< steps { _ = vm.run(&engine, info: info, callFunction: callFunction) }
        return engine
    }

    @Test("load resets the engine and points the PC at the type offset")
    func loadResets() {
        var engine = ScriptEngine()
        engine.stackPointer = 3; engine.framePointer = 9
        let info = ScriptInfo(program: [ 0, 0, 0 ], offsets: [ 0, 2 ])
        vm.load(&engine, info: info, typeID: 1)
        #expect(engine.scriptPC == 2)
        #expect(engine.framePointer == 17)
        #expect(engine.stackPointer == 15)
        #expect(vm.isLoaded(engine))
    }

    @Test("PUSH + BINARY add + POP into returnValue")
    func pushAddPop() {
        // PUSH 3; PUSH 5; (+); POP_RETURN_OR_LOCATION 0
        let prog = [ inlineOp(PUSH, 3), inlineOp(PUSH, 5), inlineOp(BINARY, 8), bareOp(POP_RET) ]
        let e = runProgram(prog, steps: 4)
        #expect(e.returnValue == 8)
        #expect(e.stackPointer == 15)  // stack emptied
    }

    @Test("inline byte parameter is sign-extended")
    func signExtendedParam() {
        // PUSH 0xFF (= -1 → 0xFFFF); POP into returnValue
        let e = runProgram([ inlineOp(PUSH, 0xFF), bareOp(POP_RET) ], steps: 2)
        #expect(e.returnValue == 0xFFFF)
    }

    @Test("BINARY covers the comparison and arithmetic ops")
    func binaryOps() {
        func eval(_ a: Int, _ b: Int, _ op: Int) -> UInt16 {
            runProgram([ inlineOp(PUSH, a), inlineOp(PUSH, b), inlineOp(BINARY, op), bareOp(POP_RET) ], steps: 4)
                .returnValue
        }

        #expect(eval(7, 3, 9) == 4)  // 7 - 3
        #expect(eval(6, 7, 10) == 42)  // 6 * 7
        #expect(eval(5, 5, 2) == 1)  // 5 == 5
        #expect(eval(5, 6, 2) == 0)  // 5 == 6
        #expect(eval(3, 5, 4) == 1)  // 3 < 5
        #expect(eval(20, 4, 11) == 5)  // 20 / 4
        #expect(eval(7, 3, 16) == 1)  // 7 % 3
        #expect(eval(0xF, 0x1, 14) == 1)  // 0xF & 1
    }

    @Test("UNARY not / negate / complement")
    func unaryOps() {
        #expect(runProgram([ inlineOp(PUSH, 0), inlineOp(UNARY, 0), bareOp(POP_RET) ], steps: 3).returnValue == 1)  // !0
        #expect(runProgram([ inlineOp(PUSH, 5), inlineOp(UNARY, 1), bareOp(POP_RET) ], steps: 3).returnValue == 0xFFFB)  // -5
        #expect(runProgram([ inlineOp(PUSH, 0), inlineOp(UNARY, 2), bareOp(POP_RET) ], steps: 3).returnValue == 0xFFFF)  // ~0
    }

    @Test("GOTO jumps over the skipped instruction")
    func gotoJump() {
        // [0] GOTO 2; [1] SETRV 99 (skipped); [2] SETRV 7
        let e = runProgram([ goto(2), inlineOp(SETRV, 99), inlineOp(SETRV, 7) ], steps: 2)
        #expect(e.returnValue == 7)
    }

    @Test("JUMP_NE: zero jumps to the parameter, non-zero falls through")
    func jumpNE() {
        // [0] PUSH t; [1] JUMP_NE 4; [2] SETRV 5; [3] GOTO 5; [4] SETRV 9; [5] SETRV-none
        func prog(_ top: Int) -> [UInt16] {
            [ inlineOp(PUSH, top), inlineOp(JUMP_NE, 4), inlineOp(SETRV, 5), goto(5), inlineOp(SETRV, 9), bareOp(SETRV) ]
        }

        // top == 0 ⇒ pops 0 ⇒ jump to [4] ⇒ SETRV 9
        #expect(runProgram(prog(0), steps: 3).returnValue == 9)
        // top == 1 ⇒ pops 1 ⇒ fall through to [2] ⇒ SETRV 5
        #expect(runProgram(prog(1), steps: 3).returnValue == 5)
    }

    @Test("FUNCTION dispatches op 14 to the injected table; unported ⇒ clean halt")
    func functionDispatch() {
        var calls = 0
        let e = runProgram([ inlineOp(FUNCTION, 5) ], steps: 1) { index, _ in
            calls += 1
            #expect(index == 5)
            return 77
        }
        #expect(calls == 1)
        #expect(e.returnValue == 77)

        // Unported native (closure returns nil) ⇒ run returns false AND the script halts (PC nulled), so
        // it stays stopped rather than silently resuming past the call (which would skew tick timing).
        var engine = ScriptEngine()
        let info = ScriptInfo(program: [ inlineOp(FUNCTION, 9) ], offsets: [ 0 ])
        vm.load(&engine, info: info, typeID: 0)
        let ok = vm.run(&engine, info: info, callFunction: { _, _ in nil })
        #expect(!ok)
        #expect(!vm.isLoaded(engine))
    }

    @Test("loadAsSubroutine + RETURN restores the caller's PC and returnValue")
    func subroutineFrame() {
        var engine = ScriptEngine()
        let info = ScriptInfo(program: [ bareOp(RETURN), bareOp(RETURN), bareOp(RETURN) ], offsets: [ 0, 2 ])
        vm.load(&engine, info: info, typeID: 0)
        engine.scriptPC = 5  // pretend the caller is mid-program
        engine.returnValue = 42

        vm.loadAsSubroutine(&engine, info: info, typeID: 1)
        #expect(engine.isSubroutine == 1)
        #expect(engine.scriptPC == 2)  // jumped to offsets[1]

        // The subroutine immediately RETURNs: pops returnValue then the saved location.
        _ = vm.run(&engine, info: info, callFunction: { _, _ in nil })
        #expect(engine.scriptPC == 5)  // caller location restored
        #expect(engine.returnValue == 42)
        #expect(engine.isSubroutine == 0)
    }

    @Test("a reset engine is not loaded and run is a no-op")
    func notLoaded() {
        var engine = ScriptEngine()  // default: PC == scriptNull
        #expect(!vm.isLoaded(engine))
        let info = ScriptInfo(program: [ bareOp(SETRV) ], offsets: [ 0 ])
        #expect(!vm.run(&engine, info: info, callFunction: { _, _ in nil }))
    }

    @Test("stack overflow drops the engine into the NULL-PC error state")
    func stackOverflow() {
        // 16 PUSHes onto a 15-slot stack ⇒ the 16th overflows.
        let prog = Array(repeating: inlineOp(PUSH, 1), count: 16)
        let e = runProgram(prog, steps: 16)
        #expect(!vm.isLoaded(e))
    }
}
