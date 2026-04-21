import Foundation
import Testing
@testable import DuneIICore

@Suite("Script_Unit_IdleAction")
struct IdleActionTests {
    @Test("IdleAction leaves winger / harvester / slither units alone")
    func skipsWhenNotGroundMovement() throws {
        for (type, _) in [
            (UInt8(0),  "Carryall / winger"),
            (UInt8(16), "Harvester"),
            (UInt8(25), "Sandworm / slither")
        ] {
            var units = Simulation.UnitPool()
            units.allocate(at: 0, type: type, houseID: 0)
            var u = units[0]
            u.orientationCurrent = 64
            u.spriteOffset = 0
            units[0] = u
            let host = Scripting.Host(
                units: units, structures: .init(),
                currentObject: .unit(poolIndex: 0),
                texts: [], textLog: [], voiceLog: []
            )
            let source = Scripting.RandomSource(lcgSeed: 1, toolsSeed: 1)
            var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
            functions[0] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
            let vm = Scripting.VM(
                program: (try? Formats.Emc.Program.decodeCode(ins(14, 0))) ?? .empty,
                functions: functions
            )
            var engine = Scripting.Engine.reset()
            _ = vm.step(&engine)
            // Unchanged: orientation + sprite offset stay put.
            #expect(host.units[0].orientationCurrent == 64)
            #expect(host.units[0].spriteOffset == 0)
        }
    }

    @Test("IdleAction can randomise orientation on a tracked unit when random roll ≤ 2")
    func tankRotation() throws {
        // Find a seed where the LCG's first range(0..10) draw is ≤ 2.
        // Rather than searching the seed space, pin behaviour against a
        // stream we pre-roll: we need `lcg.range(0,10) ≤ 2` on the first
        // call. The LCG is deterministic — seed 0x1234 produces 5 first;
        // exhaustively try a handful.
        var seed: UInt16 = 0
        for candidate in 0..<10 {
            var lcg = RNG.BorlandLCG(seed: UInt16(candidate))
            if lcg.range(0, 10) <= 2 { seed = UInt16(candidate); break }
        }
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 9, houseID: 0)   // Tank = tracked
        var u = units[0]; u.orientationCurrent = 0; units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        let source = Scripting.RandomSource(lcgSeed: seed, toolsSeed: 7)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        // Orientation must have moved off zero (matches the port's
        // `Unit_SetOrientation(Tools_Random_256())` path).
        #expect(host.units[0].orientationCurrent != 0)
    }

    @Test("IdleAction nudges spriteOffset on a foot unit when random > 8")
    func footSpriteOffset() throws {
        // Find a seed where first range(0..10) is ≥ 9.
        var seed: UInt16 = 0
        for candidate in 0..<128 {
            var lcg = RNG.BorlandLCG(seed: UInt16(candidate))
            if lcg.range(0, 10) > 8 { seed = UInt16(candidate); break }
        }
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 2, houseID: 0)   // Infantry = foot
        var u = units[0]; u.spriteOffset = 0; units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        let source = Scripting.RandomSource(lcgSeed: seed, toolsSeed: 2)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        // spriteOffset is `Tools_Random_256() & 0x3F`; non-zero outcomes
        // are overwhelmingly likely from a non-degenerate seed.
        #expect(host.units[0].spriteOffset != 0)
    }

    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }
}
