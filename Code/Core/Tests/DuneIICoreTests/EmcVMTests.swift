import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.Scripting.VM")
struct EmcVMTests {
    // MARK: - Engine reset

    @Test("Engine.reset() yields the canonical empty engine")
    func resetEngine() {
        let engine = Scripting.Engine.reset()
        #expect(engine.stackPointer == 15)
        #expect(engine.framePointer == 17)
        #expect(engine.returnValue == 0)
        #expect(engine.halted == false)
        #expect(engine.isSubroutine == false)
        #expect(engine.stack.count == 15)
        #expect(engine.stack.allSatisfy { $0 == 0 })
        #expect(engine.variables.count == 5)
        #expect(engine.variables.allSatisfy { $0 == 0 })
    }

    // MARK: - Single-opcode behaviours

    @Test("PUSH then POP_VARIABLE leaves the value in variables[0]")
    func pushPopVariable() throws {
        let vm = makeVM(words: ins(3, 0x1234) + ins(9, 0))
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .ok)         // PUSH 0x1234
        #expect(engine.stackPointer == 14)
        #expect(engine.stack[14] == 0x1234)
        #expect(vm.step(&engine) == .ok)         // POP_VARIABLE 0
        #expect(engine.stackPointer == 15)
        #expect(engine.variables[0] == 0x1234)
    }

    @Test("BINARY arithmetic computes left OP right")
    func binaryArithmetic() throws {
        // PUSH 5, PUSH 3, BINARY 8 (+) → expect TOS == 8.
        var engine = Scripting.Engine.reset()
        var vm = makeVM(words: ins(3, 5) + ins(3, 3) + ins(17, 8))
        runSteps(vm, &engine, 3)
        #expect(engine.stack[14] == 8)
        #expect(engine.stackPointer == 14)

        // PUSH 10, PUSH 3, BINARY 9 (-) → 7
        engine = Scripting.Engine.reset()
        vm = makeVM(words: ins(3, 10) + ins(3, 3) + ins(17, 9))
        runSteps(vm, &engine, 3)
        #expect(Int16(bitPattern: engine.stack[14]) == 7)

        // PUSH 6, PUSH 4, BINARY 10 (*) → 24
        engine = Scripting.Engine.reset()
        vm = makeVM(words: ins(3, 6) + ins(3, 4) + ins(17, 10))
        runSteps(vm, &engine, 3)
        #expect(engine.stack[14] == 24)

        // PUSH 5, PUSH 5, BINARY 5 (<=) → 1
        engine = Scripting.Engine.reset()
        vm = makeVM(words: ins(3, 5) + ins(3, 5) + ins(17, 5))
        runSteps(vm, &engine, 3)
        #expect(engine.stack[14] == 1)
    }

    @Test("UNARY operators")
    func unary() throws {
        // PUSH 0, UNARY 0 (!x) → 1
        var engine = Scripting.Engine.reset()
        var vm = makeVM(words: ins(3, 0) + ins(16, 0))
        runSteps(vm, &engine, 2)
        #expect(engine.stack[14] == 1)

        // PUSH 5, UNARY 1 (-x) → 0xFFFB (bit pattern of -5 as UInt16)
        engine = Scripting.Engine.reset()
        vm = makeVM(words: ins(3, 5) + ins(16, 1))
        runSteps(vm, &engine, 2)
        #expect(engine.stack[14] == 0xFFFB)

        // PUSH 0x1234, UNARY 2 (~x) → 0xEDCB
        engine = Scripting.Engine.reset()
        vm = makeVM(words: ins(3, 0x1234) + ins(16, 2))
        runSteps(vm, &engine, 2)
        #expect(engine.stack[14] == 0xEDCB)
    }

    @Test("JUMP_NE branches when TOS is zero, falls through otherwise")
    func jumpNotEqual() throws {
        // PUSH 0 (2 words), JUMP_NE 7 (2 words) — total 4 words. Padding so pc=7 is in-range.
        var engine = Scripting.Engine.reset()
        var vm = makeVM(words:
            ins(3, 0)            // words 0..1
            + ins(15, 7)         // words 2..3
            + [0xAAAA, 0xBBBB,   // 4..5
               0xCCCC, 0xDDDD]   // 6..7
        )
        #expect(vm.step(&engine) == .ok)         // PUSH 0
        #expect(vm.step(&engine) == .ok)         // JUMP_NE: TOS == 0 → branch
        #expect(engine.pc == 7)

        // Non-zero TOS → falls through.
        engine = Scripting.Engine.reset()
        vm = makeVM(words:
            ins(3, 1)
            + ins(15, 7)
            + [0, 0, 0, 0]
        )
        #expect(vm.step(&engine) == .ok)
        #expect(vm.step(&engine) == .ok)
        #expect(engine.pc == 4)
    }

    @Test("SETRETURNVALUE then PUSH_RETURN_OR_LOCATION 0 lands on the stack")
    func returnValuePush() throws {
        var engine = Scripting.Engine.reset()
        let vm = makeVM(words: ins(1, 0xAB) + ins(2, 0))
        runSteps(vm, &engine, 2)
        #expect(engine.returnValue == 0xAB)
        #expect(engine.stack[14] == 0xAB)
    }

    @Test("STACK_FORWARD allocates locals; STACK_REWIND deallocates")
    func stackAllocate() throws {
        var engine = Scripting.Engine.reset()
        let vm = makeVM(words: ins(13, 3) + ins(12, 3))
        #expect(vm.step(&engine) == .ok)
        #expect(engine.stackPointer == 12)
        #expect(vm.step(&engine) == .ok)
        #expect(engine.stackPointer == 15)
    }

    @Test("FUNCTION dispatch invokes the registered callback exactly once")
    func functionDispatch() throws {
        let calls = CallCounter()
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[5] = { engine in
            calls.increment()
            // Pop the argument and return its double.
            let popped = Int(Int16(bitPattern: Scripting.pop(engine: &engine)))
            return UInt16(truncatingIfNeeded: popped * 2)
        }
        let vm = makeVM(words: ins(3, 21) + ins(14, 5), functions: functions)
        var engine = Scripting.Engine.reset()
        runSteps(vm, &engine, 2)
        #expect(calls.value == 1)
        #expect(engine.returnValue == 42)            // 21 * 2
    }

    @Test("Unknown BINARY parameter halts the engine")
    func haltOnUnknownBinary() throws {
        let vm = makeVM(words: ins(3, 0) + ins(3, 0) + ins(17, 18))
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .ok)
        #expect(vm.step(&engine) == .ok)
        #expect(vm.step(&engine) == .halted)
        #expect(engine.halted == true)
        #expect(vm.step(&engine) == .halted)         // sticky
    }

    @Test("FUNCTION halts when slot is nil")
    func haltOnNilFunctionSlot() throws {
        let vm = makeVM(words: ins(14, 7))
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .halted)
    }

    @Test("RETURN with empty stack halts via peek-before-pop")
    func haltOnReturnEmptyStack() throws {
        let vm = makeVM(words: ins(18, 0))
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .halted)
        #expect(engine.stackPointer == 15)
    }

    @Test("Pinned 5-instruction program: 2 * 3 → variables[0]; SETRETURNVALUE 42")
    func pinnedRun() throws {
        let vm = makeVM(words:
            ins(3, 2)        // PUSH 2
            + ins(3, 3)      // PUSH 3
            + ins(17, 10)    // BINARY 10 (*)
            + ins(9, 0)      // POP_VARIABLE 0
            + ins(1, 42)     // SETRETURNVALUE 42
        )
        var engine = Scripting.Engine.reset()
        runSteps(vm, &engine, 5)
        #expect(engine.variables[0] == 6)
        #expect(engine.returnValue == 42)
        #expect(engine.stackPointer == 15)
    }

    // MARK: - Helpers

    /// Builds a 2-word EMC instruction: first word `(opcode << 8) | 0x2000`,
    /// second word the parameter. Mirrors the EMC compiler's encoding for
    /// instructions whose parameter doesn't fit in the low byte.
    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }

    private func makeVM(
        words: [UInt16],
        functions: [Scripting.VM.Function?] = Array(repeating: nil, count: 64)
    ) -> Scripting.VM {
        let program: Formats.Emc.Program
        do {
            program = try Formats.Emc.Program.decodeCode(words)
        } catch {
            // Padding words aren't always valid opcodes; the VM doesn't need
            // a successful pre-decode to run, so fall back to a hand-built
            // Program with only the raw `code` populated.
            program = Formats.Emc.Program(
                texts: [],
                entryPoints: [],
                code: words,
                instructions: [],
                wordIndexToInsn: Array(repeating: -1, count: words.count)
            )
        }
        return Scripting.VM(program: program, functions: functions)
    }

    private func runSteps(_ vm: Scripting.VM, _ engine: inout Scripting.Engine, _ steps: Int) {
        for _ in 0..<steps {
            if vm.step(&engine) == .halted { return }
        }
    }
}

/// Reference-typed counter so a `@Sendable` closure can mutate it from inside
/// a `Scripting.VM.Function` callback.
private final class CallCounter: @unchecked Sendable {
    private var _value = 0
    func increment() { _value += 1 }
    var value: Int { _value }
}
