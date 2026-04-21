import Foundation
import Testing
@testable import DuneIICore

@Suite("Scripting host batch 2 (context-aware)")
struct EmcHostFunctionsTests {
    // MARK: EncodedIndex

    @Test("EncodedIndex.unit(n) has kind .unit and decoded == n")
    func encodeUnit() {
        let e = Scripting.EncodedIndex.unit(7)
        #expect(e.kind == .unit)
        #expect(e.decoded == 7)
        #expect(e.raw == 0x4000 | 7)
    }

    @Test("EncodedIndex.structure(n) has kind .structure and decoded == n")
    func encodeStructure() {
        let e = Scripting.EncodedIndex.structure(12)
        #expect(e.kind == .structure)
        #expect(e.decoded == 12)
        #expect(e.raw == 0x8000 | 12)
    }

    @Test("EncodedIndex raw 0 is .none, never .unit(0)")
    func encodeNone() {
        let e = Scripting.EncodedIndex(raw: 0)
        #expect(e.kind == .none)
    }

    @Test("EncodedIndex 0xC000-masked values are .tile")
    func encodeTile() {
        let e = Scripting.EncodedIndex(raw: 0xC000 | 0x0001)
        #expect(e.kind == .tile)
    }

    // MARK: DisplayText

    @Test("DisplayText appends texts[peek(1)] with three args and returns 0")
    func displayTextAppends() throws {
        let host = Scripting.Host(
            units: .init(), structures: .init(),
            currentObject: nil,
            texts: ["hello", "world"],
            textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeDisplayText(host: host)

        // Program: PUSH 4; PUSH 3; PUSH 2; PUSH 1; FUNCTION 0
        // After the four PUSHes, stack top = 1 (peek(1)), next = 2, 3, 4.
        let code = ins(3, 4) + ins(3, 3) + ins(3, 2) + ins(3, 1) + ins(14, 0)
        let vm = makeVM(words: code, functions: functions)
        var engine = Scripting.Engine.reset()
        for _ in 0..<5 { _ = vm.step(&engine) }

        #expect(engine.returnValue == 0)
        #expect(host.textLog.count == 1)
        #expect(host.textLog[0].text == "world") // texts[1]
        #expect(host.textLog[0].arg1 == 2)
        #expect(host.textLog[0].arg2 == 3)
        #expect(host.textLog[0].arg3 == 4)
    }

    // MARK: UnitCount

    @Test("UnitCount counts same-type, same-house units only")
    func unitCountFiltersHouseAndType() throws {
        var units = Simulation.UnitPool()
        // House 0, type 3: two units
        units.allocate(at: 0, type: 3, houseID: 0)
        units.allocate(at: 1, type: 3, houseID: 0)
        // House 0, type 5: one unit (different type, excluded)
        units.allocate(at: 2, type: 5, houseID: 0)
        // House 1, type 3: one unit (different house, excluded)
        units.allocate(at: 3, type: 3, houseID: 1)

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeUnitCount(host: host)

        // PUSH 3 (type); FUNCTION 0
        let vm = makeVM(words: ins(3, 3) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 2)
    }

    @Test("UnitCount with no currentObject returns 0")
    func unitCountNoCurrent() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 3, houseID: 0)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil,
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeUnitCount(host: host)
        let vm = makeVM(words: ins(3, 3) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
    }

    // MARK: GetOrientation

    @Test("GetOrientation returns slot.orientationCurrent for a valid unit index")
    func getOrientationValid() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 0, houseID: 0)
        var slot = units[5]
        slot.orientationCurrent = 64
        units[5] = slot

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetOrientation(host: host)

        let encoded = Scripting.EncodedIndex.unit(5).raw
        let vm = makeVM(words: ins(3, encoded) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        // orientationCurrent 64 → UInt16 64
        #expect(engine.returnValue == 64)
    }

    @Test("GetOrientation returns 128 for an invalid / non-unit index")
    func getOrientationInvalid() throws {
        let host = Scripting.Host(
            units: .init(), structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetOrientation(host: host)

        // Pushing 0 (IT_NONE) — invalid.
        let vm = makeVM(words: ins(3, 0) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 128)
    }

    @Test("GetOrientation returns 128 when the unit slot is freed")
    func getOrientationFreedSlot() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 0, houseID: 0)
        units.free(at: 5)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetOrientation(host: host)
        let vm = makeVM(words: ins(3, Scripting.EncodedIndex.unit(5).raw) + ins(14, 0),
                        functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 128)
    }

    // MARK: IsFriendly / IsEnemy

    @Test("IsEnemy returns 1 for a different-house unit, 0 for same-house")
    func isEnemyCases() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0) // player unit (current)
        units.allocate(at: 1, type: 0, houseID: 0) // same house → friendly
        units.allocate(at: 2, type: 0, houseID: 3) // different house → enemy

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIsEnemy(host: host)

        // Same-house target → 0
        let vm1 = makeVM(words: ins(3, Scripting.EncodedIndex.unit(1).raw) + ins(14, 0),
                         functions: functions)
        var e1 = Scripting.Engine.reset()
        _ = vm1.step(&e1); _ = vm1.step(&e1)
        #expect(e1.returnValue == 0)

        // Different-house target → 1
        let vm2 = makeVM(words: ins(3, Scripting.EncodedIndex.unit(2).raw) + ins(14, 0),
                         functions: functions)
        var e2 = Scripting.Engine.reset()
        _ = vm2.step(&e2); _ = vm2.step(&e2)
        #expect(e2.returnValue == 1)
    }

    @Test("IsEnemy returns 0 for an invalid index (matches OpenDUNE)")
    func isEnemyInvalid() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIsEnemy(host: host)
        // raw=0 is invalid.
        let vm = makeVM(words: ins(3, 0) + ins(14, 0), functions: functions)
        var e = Scripting.Engine.reset()
        _ = vm.step(&e); _ = vm.step(&e)
        #expect(e.returnValue == 0)
    }

    @Test("IsFriendly returns 1 for friendly, 0xFFFF (-1) for enemy, 0 for invalid")
    func isFriendlyCases() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 0, houseID: 0)
        units.allocate(at: 1, type: 0, houseID: 0)
        units.allocate(at: 2, type: 0, houseID: 3)

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIsFriendly(host: host)

        // friendly → 1
        let vm1 = makeVM(words: ins(3, Scripting.EncodedIndex.unit(1).raw) + ins(14, 0),
                         functions: functions)
        var e1 = Scripting.Engine.reset()
        _ = vm1.step(&e1); _ = vm1.step(&e1)
        #expect(e1.returnValue == 1)

        // enemy → -1 i.e. 0xFFFF
        let vm2 = makeVM(words: ins(3, Scripting.EncodedIndex.unit(2).raw) + ins(14, 0),
                         functions: functions)
        var e2 = Scripting.Engine.reset()
        _ = vm2.step(&e2); _ = vm2.step(&e2)
        #expect(e2.returnValue == 0xFFFF)

        // invalid → 0
        let vm3 = makeVM(words: ins(3, 0) + ins(14, 0), functions: functions)
        var e3 = Scripting.Engine.reset()
        _ = vm3.step(&e3); _ = vm3.step(&e3)
        #expect(e3.returnValue == 0)
    }

    // MARK: - Helpers (mirror the pattern in EmcFunctionsTests)

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
