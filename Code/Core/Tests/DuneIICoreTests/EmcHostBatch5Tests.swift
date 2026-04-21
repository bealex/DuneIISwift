import Foundation
import Testing
@testable import DuneIICore

@Suite("Scripting host batch 5 (further generics)")
struct EmcHostBatch5Tests {
    // MARK: DelayRandom

    @Test("DelayRandom returns (tools * peek) / 256 / 5 and writes engine.delay")
    func delayRandomComputes() throws {
        let source = Scripting.RandomSource(lcgSeed: 1, toolsSeed: 42)
        // Capture the next Tools_Random_256 output for comparison.
        var preview = source.tools
        let r = UInt16(preview.next())
        let peek: UInt16 = 200
        let want = (r &* peek) / 256 / 5

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeDelayRandom(source: source)
        let vm = makeVM(words: ins(3, peek) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == want)
        #expect(engine.delay == want)
    }

    @Test("DelayRandom advances the shared Tools_Random stream")
    func delayRandomSharesToolsStream() throws {
        let source = Scripting.RandomSource(lcgSeed: 1, toolsSeed: 1)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeDelayRandom(source: source)

        let vm = makeVM(words: ins(3, 100) + ins(14, 0), functions: functions)
        var e1 = Scripting.Engine.reset()
        _ = vm.step(&e1); _ = vm.step(&e1)

        // Second call should draw the next value, not the first.
        var e2 = Scripting.Engine.reset()
        _ = vm.step(&e2); _ = vm.step(&e2)

        // Compare against a reference stream advanced twice.
        var reference = RNG.ToolsRandom256(seed: 1)
        let r1 = UInt16(reference.next())
        let r2 = UInt16(reference.next())
        #expect(e1.returnValue == (r1 &* 100) / 256 / 5)
        #expect(e2.returnValue == (r2 &* 100) / 256 / 5)
    }

    // MARK: GetIndexType / DecodeIndex

    @Test("GetIndexType returns IT_* for each kind and 0xFFFF invalid")
    func getIndexTypeKinds() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 0, houseID: 0)
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 0, houseID: 0)

        let host = Scripting.Host(
            units: units, structures: structures,
            currentObject: nil, texts: [], textLog: []
        )

        // Valid unit → IT_UNIT (2)
        #expect(runGetIndexType(host: host, raw: Scripting.EncodedIndex.unit(5).raw) == 2)
        // Valid structure → IT_STRUCTURE (3)
        #expect(runGetIndexType(host: host, raw: Scripting.EncodedIndex.structure(3).raw) == 3)
        // Valid tile (always valid per isValid) → IT_TILE (1)
        #expect(runGetIndexType(host: host, raw: 0xC000 | 0x0001) == 1)
        // None (raw = 0) → invalid → 0xFFFF
        #expect(runGetIndexType(host: host, raw: 0) == 0xFFFF)
    }

    @Test("GetIndexType returns 0xFFFF for a freed unit slot")
    func getIndexTypeFreedSlot() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 0, houseID: 0)
        units.free(at: 5)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        #expect(runGetIndexType(host: host, raw: Scripting.EncodedIndex.unit(5).raw) == 0xFFFF)
    }

    @Test("DecodeIndex returns pool index for unit/structure, packed tile for tile, 0xFFFF invalid")
    func decodeIndexKinds() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 7, type: 0, houseID: 0)
        var structures = Simulation.StructurePool()
        structures.allocate(at: 12, type: 0, houseID: 0)
        let host = Scripting.Host(
            units: units, structures: structures,
            currentObject: nil, texts: [], textLog: []
        )
        #expect(runDecodeIndex(host: host, raw: Scripting.EncodedIndex.unit(7).raw) == 7)
        #expect(runDecodeIndex(host: host, raw: Scripting.EncodedIndex.structure(12).raw) == 12)
        // Tile: Tile_PackXY((raw>>1)&0x3F, (raw>>8)&0x3F). Raw = 0xC000 | (x<<1) | (y<<8).
        // x=3, y=5 → packed = 5*64 + 3 = 323.
        let raw: UInt16 = 0xC000 | (3 << 1) | (5 << 8)
        #expect(runDecodeIndex(host: host, raw: raw) == 323)
        // Invalid (raw = 0 → kind = .none → invalid)
        #expect(runDecodeIndex(host: host, raw: 0) == 0xFFFF)
    }

    // MARK: GetLinkedUnitType

    @Test("GetLinkedUnitType returns the linked unit's type")
    func getLinkedUnitType() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 0)   // carrier
        units.allocate(at: 7, type: 9, houseID: 0)   // cargo
        var carrier = units[5]
        carrier.linkedID = 7
        units[5] = carrier
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )
        #expect(runGetLinkedUnitType(host: host) == 9)
    }

    @Test("GetLinkedUnitType returns 0xFFFF when unlinked")
    func getLinkedUnitTypeUnlinked() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 0)
        // linkedID defaults to 0xFF via allocate().
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )
        #expect(runGetLinkedUnitType(host: host) == 0xFFFF)
    }

    @Test("GetLinkedUnitType works on a structure currentObject")
    func getLinkedUnitTypeFromStructure() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 4, type: 6, houseID: 1)
        var structures = Simulation.StructurePool()
        structures.allocate(at: 2, type: 0, houseID: 1)
        var s = structures[2]
        s.linkedID = 4
        structures[2] = s
        let host = Scripting.Host(
            units: units, structures: structures,
            currentObject: .structure(poolIndex: 2),
            texts: [], textLog: []
        )
        #expect(runGetLinkedUnitType(host: host) == 6)
    }

    // MARK: FindIdle

    @Test("FindIdle in structure-index mode: same-house + IDLE → 1")
    func findIdleIndexIdle() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 1, type: 0, houseID: 2) // current
        structures.allocate(at: 3, type: 5, houseID: 2) // target
        var s = structures[3]
        s.state = 0 // IDLE
        structures[3] = s
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 1),
            texts: [], textLog: []
        )
        let raw = Scripting.EncodedIndex.structure(3).raw
        #expect(runFindIdle(host: host, raw: raw) == 1)
    }

    @Test("FindIdle in structure-index mode: non-IDLE or different house → 0")
    func findIdleIndexNegative() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 1, type: 0, houseID: 2)
        structures.allocate(at: 3, type: 5, houseID: 2)
        structures.allocate(at: 4, type: 5, houseID: 9)
        var s = structures[3]
        s.state = 1 // BUSY
        structures[3] = s
        var s4 = structures[4]
        s4.state = 0 // IDLE but wrong house
        structures[4] = s4
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 1),
            texts: [], textLog: []
        )
        #expect(runFindIdle(host: host, raw: Scripting.EncodedIndex.structure(3).raw) == 0)
        #expect(runFindIdle(host: host, raw: Scripting.EncodedIndex.structure(4).raw) == 0)
    }

    @Test("FindIdle in type-search mode returns the first IDLE match")
    func findIdleTypeSearchHit() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 1, type: 0, houseID: 2) // current
        structures.allocate(at: 3, type: 5, houseID: 2) // busy
        structures.allocate(at: 7, type: 5, houseID: 2) // idle match
        var s = structures[3]
        s.state = 1 // BUSY
        structures[3] = s
        // slot 7 leaves state = 0 (IDLE) by default
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 1),
            texts: [], textLog: []
        )
        #expect(runFindIdle(host: host, raw: 5) == Scripting.EncodedIndex.structure(7).raw)
    }

    @Test("FindIdle in type-search mode returns 0 when nothing is IDLE")
    func findIdleTypeSearchMiss() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 1, type: 0, houseID: 2)
        structures.allocate(at: 3, type: 5, houseID: 2)
        var s = structures[3]
        s.state = 1 // BUSY
        structures[3] = s
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 1),
            texts: [], textLog: []
        )
        #expect(runFindIdle(host: host, raw: 5) == 0)
    }

    @Test("FindIdle with IT_UNIT or IT_TILE encoded arg returns 0")
    func findIdleUnitOrTileShortCircuits() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 2, type: 0, houseID: 2)
        var structures = Simulation.StructurePool()
        structures.allocate(at: 1, type: 0, houseID: 2)
        let host = Scripting.Host(
            units: units, structures: structures,
            currentObject: .structure(poolIndex: 1),
            texts: [], textLog: []
        )
        #expect(runFindIdle(host: host, raw: Scripting.EncodedIndex.unit(2).raw) == 0)
        #expect(runFindIdle(host: host, raw: 0xC000 | 0x0001) == 0)
    }

    // MARK: Helpers

    private func runGetIndexType(host: Scripting.Host, raw: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetIndexType(host: host)
        let vm = makeVM(words: ins(3, raw) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runDecodeIndex(host: Scripting.Host, raw: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeDecodeIndex(host: host)
        let vm = makeVM(words: ins(3, raw) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runGetLinkedUnitType(host: Scripting.Host) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetLinkedUnitType(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runFindIdle(host: Scripting.Host, raw: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeFindIdle(host: host)
        let vm = makeVM(words: ins(3, raw) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        return engine.returnValue
    }

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
