import Foundation
import Testing
@testable import DuneIICore

@Suite("Scripting host batch 3 (unit-specific)")
struct EmcHostUnitFunctionsTests {
    // MARK: GetInfo

    @Test("GetInfo sweeps supported subcases against pinned slot fields")
    func getInfoSubcases() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 2)
        var slot = units[5]
        slot.orientationCurrent = 64
        slot.targetAttack = 0x4010            // unit at index 0x10, valid
        slot.originEncoded = 0x8008           // structure at index 0x08
        slot.targetMove = 0                   // invalid → 0x01 returns 0
        units[5] = slot
        // Make the structure at index 8 live so `isValid` wouldn't block
        // a non-zero targetMove — here we test the invalid path directly.

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )

        let expected: [(UInt16, UInt16)] = [
            (0x01, 0),                                              // targetMove invalid → 0
            (0x03, 5),                                              // index
            (0x04, 64),                                             // orientation
            (0x05, 0x4010),                                         // targetAttack
            (0x06, 0x8008),                                         // originEncoded
            (0x07, 3),                                              // type
            (0x08, Scripting.EncodedIndex.unit(5).raw),             // encode
            (0x0E, 2),                                              // houseID
            (0x00, 0),                                              // unsupported → 0 (deferred UnitInfo table)
            (0x12, 0)                                               // unsupported → 0
        ]
        for (which, want) in expected {
            let got = runGetInfo(host: host, which: which)
            #expect(got == want, "GetInfo subcase 0x\(String(which, radix: 16)) → \(got), want \(want)")
        }
    }

    @Test("GetInfo with no current unit returns 0")
    func getInfoNoCurrent() throws {
        let host = Scripting.Host(
            units: .init(), structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        #expect(runGetInfo(host: host, which: 0x07) == 0)
        #expect(runGetInfo(host: host, which: 0x0E) == 0)
    }

    @Test("GetInfo 0x01 returns targetMove when the encoded index resolves")
    func getInfoTargetMoveValid() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 2) // current
        units.allocate(at: 7, type: 0, houseID: 2) // target of targetMove
        var slot = units[5]
        slot.targetMove = Scripting.EncodedIndex.unit(7).raw
        units[5] = slot

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )
        #expect(runGetInfo(host: host, which: 0x01) == Scripting.EncodedIndex.unit(7).raw)
    }

    // MARK: SetAction

    @Test("SetAction writes peek(1) & 0xFF to the current unit and returns 0")
    func setActionWrites() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 2)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetActionUnit(host: host)
        // PUSH 0x0107 (action = 7 after narrowing); FUNCTION 0
        let vm = makeVM(words: ins(3, 0x0107) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
        #expect(host.units[5].actionID == 7)
    }

    @Test("SetAction with no current unit is a no-op")
    func setActionNoCurrent() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 2)
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetActionUnit(host: host)
        let vm = makeVM(words: ins(3, 9) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        #expect(engine.returnValue == 0)
        #expect(host.units[5].actionID == 0)
    }

    // MARK: GetAmount

    @Test("GetAmount returns slot.amount on a non-linked unit")
    func getAmountUnlinked() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 2)
        var slot = units[5]
        slot.amount = 42
        units[5] = slot
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )
        #expect(runGetAmount(host: host) == 42)
    }

    @Test("GetAmount follows linkedID to the linked unit's amount")
    func getAmountLinked() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 5, type: 3, houseID: 2)   // transport
        units.allocate(at: 9, type: 0, houseID: 2)   // cargo
        var carrier = units[5]
        carrier.amount = 1
        carrier.linkedID = 9
        units[5] = carrier
        var cargo = units[9]
        cargo.amount = 77
        units[9] = cargo
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 5),
            texts: [], textLog: []
        )
        #expect(runGetAmount(host: host) == 77)
    }

    @Test("GetAmount with no current unit returns 0")
    func getAmountNoCurrent() throws {
        let host = Scripting.Host(
            units: .init(), structures: .init(),
            currentObject: nil, texts: [], textLog: []
        )
        #expect(runGetAmount(host: host) == 0)
    }

    // MARK: WorldSnapshot plumbing

    @Test("WorldSnapshot populates the new UnitSlot fields from _SAVE001.DAT")
    func worldSnapshotRealSave() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let game = try Formats.Save.Game.decode(data)
        let baseline = Map.empty()
        let snap = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        #expect(!game.units.slots.isEmpty)
        for record in game.units.slots {
            let idx = Int(record.object.index)
            let live = snap.units[idx]
            #expect(live.actionID == record.actionID)
            #expect(live.amount == record.amount)
            #expect(live.targetAttack == record.targetAttack)
            #expect(live.targetMove == record.targetMove)
            #expect(live.originEncoded == record.originEncoded)
        }
    }

    // MARK: Helpers

    private func runGetInfo(host: Scripting.Host, which: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetInfoUnit(host: host)
        let vm = makeVM(words: ins(3, which) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runGetAmount(host: Scripting.Host) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetAmountUnit(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        return engine.returnValue
    }

    // MARK: SetActionDefault

    @Test("SetActionDefault writes actionsPlayer[3] to actionID + clears currentDestination")
    func setActionDefaultWrites() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 7, type: 13, houseID: 1)  // Trike → actionsPlayer[3] = guard_ (3)
        var slot = units[7]
        slot.actionID = Simulation.ActionID.move  // 1
        slot.currentDestinationX = 1234
        slot.currentDestinationY = 5678
        units[7] = slot

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 7),
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0x0A] = Scripting.Functions.makeSetActionDefaultUnit(host: host)
        let vm = makeVM(words: ins(14, 0x0A), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)

        #expect(host.units[7].actionID == Simulation.ActionID.guard_)
        #expect(host.units[7].currentDestinationX == 0)
        #expect(host.units[7].currentDestinationY == 0)
    }

    @Test("SetActionDefault with no current object is a no-op")
    func setActionDefaultNoCurrent() throws {
        let units = Simulation.UnitPool()
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil,
            texts: [], textLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0x0A] = Scripting.Functions.makeSetActionDefaultUnit(host: host)
        let vm = makeVM(words: ins(14, 0x0A), functions: functions)
        var engine = Scripting.Engine.reset()
        // Runs without crashing or mutating anything.
        _ = vm.step(&engine)
        #expect(host.units == units)
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
