import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.Scripting.Functions")
struct EmcFunctionsTests {
    @Test("Engine.reset() initialises delay to 0")
    func resetInitialisesDelay() {
        let engine = Scripting.Engine.reset()
        #expect(engine.delay == 0)
    }

    @Test("NoOperation returns 0 and leaves the stack untouched")
    func noOperation() throws {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[1] = Scripting.Functions.noOperation
        let vm = makeVM(words: ins(3, 42) + ins(14, 1), functions: functions)
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .ok)            // PUSH 42
        #expect(vm.step(&engine) == .ok)            // FUNCTION 1
        #expect(engine.returnValue == 0)
        #expect(engine.stackPointer == 14)          // not popped
        #expect(engine.stack[14] == 42)
    }

    @Test("Delay writes engine.delay = peek(1) / 5 and returns it")
    func delayDividesByFive() throws {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.delay
        let vm = makeVM(words: ins(3, 25) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .ok)            // PUSH 25
        #expect(vm.step(&engine) == .ok)            // FUNCTION 0 (delay)
        #expect(engine.delay == 5)
        #expect(engine.returnValue == 5)
        #expect(engine.stackPointer == 14)          // arg still on stack
        #expect(engine.stack[14] == 25)
    }

    @Test("Delay truncates sub-5-tick requests to zero")
    func delayTruncates() throws {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.delay
        let vm = makeVM(words: ins(3, 4) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        #expect(vm.step(&engine) == .ok)
        #expect(vm.step(&engine) == .ok)
        #expect(engine.delay == 0)
        #expect(engine.returnValue == 0)
    }

    @Test("RandomRange returns a value inside [lo, hi]")
    func randomRangeBounds() throws {
        let source = Scripting.RandomSource(seed: 1)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[2] = Scripting.Functions.makeRandomRange(source: source)
        let vm = makeVM(words: ins(3, 10) + ins(3, 20) + ins(14, 2), functions: functions)
        var engine = Scripting.Engine.reset()
        for _ in 0..<3 { _ = vm.step(&engine) }
        #expect(engine.returnValue >= 10 && engine.returnValue <= 20)
    }

    @Test("RandomRange shares LCG state between consecutive calls")
    func randomRangeSharedState() throws {
        // Draw once via a direct BorlandLCG; draw once via the host-fn factory
        // backed by a RandomSource built from the same seed. The two values
        // must match — the closure is drawing from the same underlying stream.
        let seed: UInt16 = 1234
        var reference = RNG.BorlandLCG(seed: seed)
        let expected = reference.range(10, 20)

        let source = Scripting.RandomSource(seed: seed)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[2] = Scripting.Functions.makeRandomRange(source: source)
        let vm = makeVM(words: ins(3, 10) + ins(3, 20) + ins(14, 2), functions: functions)
        var engine = Scripting.Engine.reset()
        for _ in 0..<3 { _ = vm.step(&engine) }
        #expect(engine.returnValue == expected)
    }

    // MARK: - Helpers (shared pattern with EmcVMTests)

    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }

    private func makeVM(
        words: [UInt16],
        functions: [Scripting.VM.Function?]
    ) -> Scripting.VM {
        let program = (try? Formats.Emc.Program.decodeCode(words)) ?? Formats.Emc.Program(
            texts: [],
            entryPoints: [],
            code: words,
            instructions: [],
            wordIndexToInsn: Array(repeating: -1, count: words.count)
        )
        return Scripting.VM(program: program, functions: functions)
    }
}
