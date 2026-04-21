import Foundation
import Testing
@testable import DuneIICore

@Suite("Scheduler naive movement + SetDestination")
struct NaiveMovementTests {
    @Test("SetDestinationUnit writes targetMove when encoded is valid")
    func setDestinationWrites() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)
        units.allocate(at: 1, type: 0, houseID: 0)  // target
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetDestinationUnit(host: host)
        let encoded = Scripting.EncodedIndex.unit(1).raw
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(
                [(UInt16(3) << 8) | 0x2000, encoded, (UInt16(14) << 8) | 0x2000, 0]
            )) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(host.units[0].targetMove == encoded)
    }

    @Test("SetDestinationUnit clears targetMove for raw=0 / invalid")
    func setDestinationClears() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)
        var u = units[0]; u.targetMove = 0x4001; units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeSetDestinationUnit(host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(
                [(UInt16(3) << 8) | 0x2000, 0, (UInt16(14) << 8) | 0x2000, 0]
            )) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        #expect(host.units[0].targetMove == 0)
    }

    @Test("Scheduler.tick advances a moving unit toward its targetMove")
    func tickAdvancesPosition() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 13, houseID: 0)  // Trike — wheeled
        units.allocate(at: 1, type: 9, houseID: 0)
        var u = units[0]
        u.positionX = 256       // tile (1, 1)
        u.positionY = 256
        u.speed = 64            // step = max(4, 16) = 16 px/tick
        u.targetMove = Scripting.EncodedIndex.unit(1).raw
        units[0] = u
        var target = units[1]
        target.positionX = 2560 // tile (10, 1)
        target.positionY = 256
        units[1] = target

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: [], voiceLog: []
        )
        let emptyFunctions = [Scripting.VM.Function?](repeating: nil, count: 64)
        var scheduler = Simulation.Scheduler(
            host: host,
            unitVM: Scripting.VM(program: .empty, functions: emptyFunctions),
            structureVM: Scripting.VM(program: .empty, functions: emptyFunctions)
        )
        let before = host.units[0].positionX
        scheduler.tick()
        let after = host.units[0].positionX
        #expect(after > before)
        // Moves exactly one step.
        #expect(Int32(after) - Int32(before) == 16)
    }

    @Test("Unit arrives and clears targetMove within arrivalThreshold")
    func tickArrives() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 13, houseID: 0)
        units.allocate(at: 1, type: 9, houseID: 0)
        var u = units[0]
        u.positionX = 1000
        u.positionY = 1000
        u.targetMove = Scripting.EncodedIndex.unit(1).raw
        units[0] = u
        var tgt = units[1]
        tgt.positionX = 1005  // dx=5, dy=5, sum=10 ≤ threshold 16
        tgt.positionY = 1005
        units[1] = tgt

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: [], voiceLog: []
        )
        let emptyFunctions = [Scripting.VM.Function?](repeating: nil, count: 64)
        var scheduler = Simulation.Scheduler(
            host: host,
            unitVM: Scripting.VM(program: .empty, functions: emptyFunctions),
            structureVM: Scripting.VM(program: .empty, functions: emptyFunctions)
        )
        scheduler.tick()
        #expect(host.units[0].targetMove == 0)
        #expect(host.units[0].positionX == 1005)
        #expect(host.units[0].positionY == 1005)
    }

    @Test("Unit with no targetMove stays put across many ticks")
    func tickStaysPut() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)
        var u = units[0]
        u.positionX = 500; u.positionY = 500
        // no targetMove.
        units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: [], voiceLog: []
        )
        let emptyFunctions = [Scripting.VM.Function?](repeating: nil, count: 64)
        var scheduler = Simulation.Scheduler(
            host: host,
            unitVM: Scripting.VM(program: .empty, functions: emptyFunctions),
            structureVM: Scripting.VM(program: .empty, functions: emptyFunctions)
        )
        for _ in 0..<10 { scheduler.tick() }
        #expect(host.units[0].positionX == 500)
        #expect(host.units[0].positionY == 500)
    }
}
