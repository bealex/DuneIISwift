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

    @Test("IdleAction consumes 2 RNG bytes on the rotation branch even though orientation stays put")
    func tankRotationConsumesRNG() throws {
        // OpenDUNE's `Unit_SetOrientation(u, randomByte, rotateInstantly=false, i)`
        // writes `orientation[i].target + .speed`, not `.current` — rotation
        // applies gradually via `tickRotation`. We don't track target/speed
        // on `UnitSlot` yet, so this IdleAction branch is a RNG-consuming
        // no-op for now: two tools bytes drawn (turret-index selector +
        // new target orientation), `orientationCurrent` unchanged.
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
        // Orientation unchanged: we don't write current without target/speed.
        #expect(host.units[0].orientationCurrent == 0)
    }

    @Test("IdleAction nudges spriteOffset on a FOOT unit when the LCG gate rolls > 8")
    func footSpriteOffset() throws {
        // Port of `src/script/unit.c:1764..1766`: the sprite-offset
        // write fires when `movementType == MOVEMENT_FOOT` AND the
        // gate roll `Tools_RandomLCG_Range(0, 10) > 8` (2/11 chance).
        // Pick an LCG seed that rolls 9 or 10, and a Tools_Random_256
        // seed whose first byte has `& 0x3F != 0` so the assertion is
        // robust (the spriteOffset write is `byte & 0x3F`).
        var lcgSeed: UInt16 = 0
        for candidate in 0..<1024 {
            var lcg = RNG.BorlandLCG(seed: UInt16(truncatingIfNeeded: candidate))
            if lcg.range(0, 10) > 8 {
                lcgSeed = UInt16(truncatingIfNeeded: candidate)
                break
            }
        }
        var toolsSeed: UInt32 = 1
        for candidate in UInt32(1)..<UInt32(256) {
            var t = RNG.ToolsRandom256(seed: candidate)
            if (t.next() & 0x3F) != 0 { toolsSeed = candidate; break }
        }
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 2, houseID: 0)   // INFANTRY (MOVEMENT_FOOT)
        var u = units[0]
        u.spriteOffset = 0
        units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        let source = Scripting.RandomSource(lcgSeed: lcgSeed, toolsSeed: toolsSeed)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(host.units[0].spriteOffset != 0)
    }

    @Test("IdleAction leaves spriteOffset alone when the LCG gate rolls ≤ 8")
    func footSpriteOffsetGateClosed() throws {
        // Complement of `footSpriteOffset`: same setup but an LCG seed
        // whose `range(0, 10)` rolls ≤ 8. The 9/11 outcome skips the
        // sprite write entirely — OpenDUNE `src/script/unit.c:1764`
        // requires `random > 8`, not `>= 8`.
        var lcgSeed: UInt16 = 0
        for candidate in 0..<1024 {
            var lcg = RNG.BorlandLCG(seed: UInt16(truncatingIfNeeded: candidate))
            let r = lcg.range(0, 10)
            // Want the gate closed (≤ 8) but `random > 2` so we don't
            // then go draw orientation Tools bytes — this isolates the
            // sprite-write gate.
            if r > 2 && r <= 8 {
                lcgSeed = UInt16(truncatingIfNeeded: candidate)
                break
            }
        }
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 2, houseID: 0)   // INFANTRY (MOVEMENT_FOOT)
        var u = units[0]; u.spriteOffset = 11; units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        let source = Scripting.RandomSource(lcgSeed: lcgSeed, toolsSeed: 1)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(host.units[0].spriteOffset == 11)
    }

    @Test("IdleAction skips body rotation half the time (i==1 → turret-target; no-op on non-turret unit)")
    func turretHalfSkip() throws {
        // OpenDUNE picks `i = (byte & 1) == 0 ? 1 : 0` — so when the
        // drawn `Tools_Random_256()` byte is EVEN, `i == 1` and the
        // orientation writes land on the turret (which our slot doesn't
        // model yet). A trike has no turret; body must stay put.
        //
        // Pick a toolsSeed whose first `next()` byte is EVEN + an LCG
        // seed that passes the `random > 2` gate.
        var lcgSeed: UInt16 = 0
        for candidate in 0..<50 {
            var lcg = RNG.BorlandLCG(seed: UInt16(candidate))
            if lcg.range(0, 10) <= 2 { lcgSeed = UInt16(candidate); break }
        }
        var toolsSeed: UInt32 = 0
        for candidate in 1..<256 {
            var t = RNG.ToolsRandom256(seed: UInt32(candidate))
            if (t.next() & 1) == 0 { toolsSeed = UInt32(candidate); break }
        }
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 13, houseID: 0)  // Trike — no turret
        var u = units[0]; u.orientationCurrent = 64; units[0] = u
        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        let source = Scripting.RandomSource(lcgSeed: lcgSeed, toolsSeed: toolsSeed)
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
        let vm = Scripting.VM(
            program: (try? Formats.Emc.Program.decodeCode(ins(14, 0))) ?? .empty,
            functions: functions
        )
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine)
        #expect(host.units[0].orientationCurrent == 64,
                "Body orientation should stay at 64: the even first-byte path targets the turret.")
    }

    private func ins(_ opcode: UInt8, _ parameter: UInt16) -> [UInt16] {
        return [(UInt16(opcode) << 8) | 0x2000, parameter]
    }
}
