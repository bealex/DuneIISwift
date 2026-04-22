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
        // Post-setSpeed port: use the shape produced by
        // `Units.setSpeed` — speed=tile-hop clamp, speedPerTick=
        // accumulator increment. Tick 1 accumulates to 255, tick 2
        // overflows and fires the move.
        u.speed = 15
        u.speedPerTick = 255
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
        // Run 2 ticks: subpixel accumulator overflows on tick 2.
        scheduler.tick()
        scheduler.tick()
        let after = host.units[0].positionX
        #expect(after > before)
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

    @Test("Route-driven orientation is locked to route[0] * 32 across ticks, even when off-axis")
    func routeOrientationStableOffAxis() throws {
        // Regression: if `tickMovement` recomputes orientation from the
        // continuous pos32 delta, small cross-axis drift can straddle an
        // octant boundary (byte ≈ 240 for N↔NW) and flip the sprite each
        // tick. The fix locks orientation to `route[0] * 32` while
        // following a route step.
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 13, houseID: 0)  // Trike (wheeled)
        var u = units[0]
        // Start at tile (5, 5) but 6 px west of centre. That asymmetry
        // would make the continuous direction from unit→N-tile-centre
        // skew toward NW (byte > 224) rather than land on 0 (N).
        u.positionX = 5 * 256 + 128 - 6   // 1402 (off-centre west by 6)
        u.positionY = 5 * 256 + 128        // 1408 (on-centre)
        u.speed = 128
        u.route[0] = 0   // N
        u.route[1] = 0   // N (second step) — keeps route alive after first pop
        u.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(3 * 64 + 5)).raw  // tile (5, 3) to the north
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
        // First tick: populates currentDestination, takes one step.
        scheduler.tick()
        // route[0] is still 0 (north-bound). Orientation must be exactly
        // `0 * 32 = 0`, not a byte drifted toward NW by the x-offset.
        #expect(host.units[0].orientationCurrent == 0,
                "Orientation should be pinned to route[0] * 32 (=0 for N), got \(host.units[0].orientationCurrent)")

        // Several more ticks, all while route[0]=0 is active.
        for _ in 0..<3 { scheduler.tick() }
        #expect(host.units[0].orientationCurrent == 0,
                "Orientation must remain 0 (N) across ticks — no drift.")
    }
}
