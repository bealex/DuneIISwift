import Foundation
import Testing
@testable import DuneIICore

@Suite("Scripting host batch 4 (structure-specific)")
struct EmcHostStructureFunctionsTests {
    // MARK: GetState

    @Test("GetState returns s.state reinterpret-cast to UInt16")
    func getStateSignedRoundTrip() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 7, houseID: 1)
        var slot = structures[3]
        slot.state = -1
        structures[3] = slot
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 3),
            texts: [], textLog: []
        )
        #expect(runGetState(host: host) == 0xFFFF)

        // And an in-range positive value.
        var slot2 = host.structures[3]
        slot2.state = 2
        host.structures[3] = slot2
        #expect(runGetState(host: host) == 2)
    }

    @Test("GetState with no current structure returns 0")
    func getStateNoCurrent() throws {
        let host = Scripting.Host(
            units: .init(), structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        #expect(runGetState(host: host) == 0)
    }

    // MARK: SetState — non-DETECT

    @Test("SetState writes an explicit non-DETECT value and returns 0")
    func setStateExplicit() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 7, houseID: 1)
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 3),
            texts: [], textLog: []
        )
        let rv = runSetState(host: host, peek: 2) // READY
        #expect(rv == 0)
        #expect(host.structures[3].state == 2)
    }

    // MARK: SetState — DETECT branches

    @Test("SetState DETECT with linkedID == 0xFF resolves to IDLE")
    func setStateDetectIdle() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 7, houseID: 1)
        // linkedID defaults to 0xFF via allocate().
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 3),
            texts: [], textLog: []
        )
        _ = runSetState(host: host, peek: UInt16(bitPattern: Int16(-2)))
        #expect(host.structures[3].state == 0)
    }

    @Test("SetState DETECT with linked & countDown == 0 resolves to READY")
    func setStateDetectReady() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 7, houseID: 1)
        var slot = structures[3]
        slot.linkedID = 5
        slot.countDown = 0
        structures[3] = slot
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 3),
            texts: [], textLog: []
        )
        _ = runSetState(host: host, peek: UInt16(bitPattern: Int16(-2)))
        #expect(host.structures[3].state == 2)
    }

    @Test("SetState DETECT with linked & countDown != 0 resolves to BUSY")
    func setStateDetectBusy() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 7, houseID: 1)
        var slot = structures[3]
        slot.linkedID = 5
        slot.countDown = 12
        structures[3] = slot
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: .structure(poolIndex: 3),
            texts: [], textLog: []
        )
        _ = runSetState(host: host, peek: UInt16(bitPattern: Int16(-2)))
        #expect(host.structures[3].state == 1)
    }

    @Test("SetState with no current structure is a no-op")
    func setStateNoCurrent() throws {
        var structures = Simulation.StructurePool()
        structures.allocate(at: 3, type: 7, houseID: 1)
        let host = Scripting.Host(
            units: .init(), structures: structures,
            currentObject: nil, texts: [], textLog: []
        )
        let rv = runSetState(host: host, peek: 2)
        #expect(rv == 0)
        #expect(host.structures[3].state == 0)
    }

    // MARK: WorldSnapshot plumbing

    @Test("WorldSnapshot populates state + countDown from _SAVE001.DAT structures")
    func worldSnapshotRealSave() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let game = try Formats.Save.Game.decode(data)
        let baseline = Map.empty()
        let snap = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        #expect(!game.structures.slots.isEmpty)
        for record in game.structures.slots {
            let idx = Int(record.object.index)
            // Reserved slots [79, 81] don't carry state/countDown overrides — they
            // go through allocateReserved. Vanilla saves never place records
            // there, but we defend the access anyway.
            guard idx < Simulation.StructurePool.capacitySoft else { continue }
            let live = snap.structures[idx]
            #expect(live.state == record.state)
            #expect(live.countDown == record.countDown)
        }
    }

    // MARK: Helpers

    private func runGetState(host: Scripting.Host) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetStateStructure(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runSetState(host: Scripting.Host, peek: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetStateStructure(host: host)
        let vm = makeVM(words: ins(3, peek) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
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
