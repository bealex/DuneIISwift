import Foundation
import Testing
@testable import DuneIICore

@Suite("Structure combat — slots 0x08 / 0x09 / 0x0A / 0x0B")
struct StructureCombatTests {

    // MARK: FindTargetUnit (0x08)

    @Test("FindTargetUnit returns encoded unit of nearest non-ally in range")
    func findTargetReturnsNearest() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0) // TURRET
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret

        // Enemy QUAD at tile 3 (pos32 896).
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 896; enemy.positionY = 128; enemy.seenByHouses = 0xFF
        host.units[30] = enemy

        host.currentObject = .structure(poolIndex: 5)
        // Range 4 tiles = 1024 pos32. Call with peek(1) = 1024.
        #expect(runFindTarget(host: host, range: 1024)
                == Scripting.EncodedIndex.unit(30).raw)
    }

    @Test("FindTargetUnit skips allied units")
    func findTargetSkipsAllied() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret

        _ = host.units.allocate(at: 30, type: 15, houseID: 0)  // allied
        var friend = host.units[30]
        friend.positionX = 384; friend.positionY = 128; friend.seenByHouses = 0xFF
        host.units[30] = friend

        host.currentObject = .structure(poolIndex: 5)
        #expect(runFindTarget(host: host, range: 2048) == 0)
    }

    @Test("FindTargetUnit skips out-of-range targets")
    func findTargetSkipsFar() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret

        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 5120; enemy.positionY = 128; enemy.seenByHouses = 0xFF // tile 20
        host.units[30] = enemy

        host.currentObject = .structure(poolIndex: 5)
        // Range 2 tiles = 512 pos32. Enemy at 5120 is way beyond.
        #expect(runFindTarget(host: host, range: 512) == 0)
    }

    @Test("FindTargetUnit allows ornithopters at 3x the stated range")
    func findTargetOrnithopter3x() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret

        // ORNITHOPTER (type 1) at tile 6 (pos32 1664). Range 1024 alone
        // would be too far, but 3×1024 = 3072 covers it.
        _ = host.units.allocate(at: 0, type: 1, houseID: 1)
        var orni = host.units[0]
        orni.positionX = 1664; orni.positionY = 128
        host.units[0] = orni

        host.currentObject = .structure(poolIndex: 5)
        let result = runFindTarget(host: host, range: 1024)
        #expect(result == Scripting.EncodedIndex.unit(0).raw)
    }

    // MARK: RotateTurret (0x09)

    @Test("RotateTurret steps one octant per call and returns 1 until aligned")
    func rotateTurretSteps() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        turret.rotationSpriteDiff = 0 // facing N
        host.structures[5] = turret

        // Target far east of turret → orientation needed is 64 (E) → octant 2.
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 5120; enemy.positionY = 128; enemy.seenByHouses = 0xFF
        host.units[30] = enemy

        host.currentObject = .structure(poolIndex: 5)
        let encoded = Scripting.EncodedIndex.unit(30).raw

        #expect(runRotateTurret(host: host, encoded: encoded) == 1)
        #expect(host.structures[5].rotationSpriteDiff == 1) // N → NE
        #expect(runRotateTurret(host: host, encoded: encoded) == 1)
        #expect(host.structures[5].rotationSpriteDiff == 2) // NE → E aligned
        #expect(runRotateTurret(host: host, encoded: encoded) == 0) // aligned
    }

    @Test("RotateTurret returns 0 without moving on encoded == 0")
    func rotateTurretZero() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.rotationSpriteDiff = 3
        host.structures[5] = turret
        host.currentObject = .structure(poolIndex: 5)
        #expect(runRotateTurret(host: host, encoded: 0) == 0)
        #expect(host.structures[5].rotationSpriteDiff == 3)
    }

    // MARK: GetDirection (0x0A)

    @Test("GetDirection returns rotationSpriteDiff << 5 for invalid target")
    func getDirectionInvalid() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.rotationSpriteDiff = 3
        host.structures[5] = turret
        host.currentObject = .structure(poolIndex: 5)
        // Encoded = 0 (none) is invalid.
        #expect(runGetDirection(host: host, encoded: 0) == 3 * 32)
    }

    @Test("GetDirection returns target octant << 5 for valid target")
    func getDirectionValid() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 5120; enemy.positionY = 128; enemy.seenByHouses = 0xFF
        host.units[30] = enemy
        host.currentObject = .structure(poolIndex: 5)
        // Direction to east is orientation 64 → octant 2 → 64.
        #expect(runGetDirection(host: host, encoded: Scripting.EncodedIndex.unit(30).raw) == 64)
    }

    // MARK: Structure Fire (0x0B)

    @Test("Fire spawns a BULLET from a TURRET with 20 damage")
    func fireTurret() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0) // TURRET
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 640; enemy.positionY = 128; enemy.seenByHouses = 0xFF
        host.units[30] = enemy

        host.currentObject = .structure(poolIndex: 5)
        let delay = runStructureFire(
            host: host, targetEncoded: Scripting.EncodedIndex.unit(30).raw
        )
        // TANK.fireDelay = 80.
        #expect(delay == 80)

        var bulletIdx: Int?
        for i in 12...15 where host.units[i].isUsed { bulletIdx = i; break }
        #expect(bulletIdx != nil)
        let bullet = host.units[bulletIdx!]
        #expect(bullet.type == 23) // BULLET
        #expect(bullet.hitpoints == 20) // turret damage
        #expect(bullet.originEncoded == Scripting.EncodedIndex.structure(5).raw)
    }

    @Test("Fire from a ROCKET_TURRET at long range uses MISSILE_TURRET")
    func fireRocketTurret() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 16, houseID: 0) // ROCKET_TURRET
        var turret = host.structures[5]
        turret.positionX = 128; turret.positionY = 128
        host.structures[5] = turret
        // Target at ≥ 0x300 = 768 pos32.
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 2048; enemy.positionY = 128; enemy.seenByHouses = 0xFF
        host.units[30] = enemy
        host.currentObject = .structure(poolIndex: 5)

        let delay = runStructureFire(
            host: host, targetEncoded: Scripting.EncodedIndex.unit(30).raw
        )
        // LAUNCHER.fireDelay = 120.
        #expect(delay == 120)
        var bulletIdx: Int?
        for i in 12...15 where host.units[i].isUsed { bulletIdx = i; break }
        #expect(bulletIdx != nil)
        #expect(host.units[bulletIdx!].type == 20) // MISSILE_TURRET
        #expect(host.units[bulletIdx!].hitpoints == 30)
    }

    @Test("Fire with variables[2] == 0 is a no-op")
    func fireNoTarget() throws {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 15, houseID: 0)
        host.currentObject = .structure(poolIndex: 5)
        let delay = runStructureFire(host: host, targetEncoded: 0)
        #expect(delay == 0)
    }

    // MARK: Helpers

    private func makeHost() -> Scripting.Host {
        Scripting.Host(
            units: Simulation.UnitPool(),
            structures: Simulation.StructurePool(),
            explosions: Simulation.ExplosionPool(),
            playerHouseID: 0
        )
    }

    private func runFindTarget(host: Scripting.Host, range: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeFindTargetUnitStructure(host: host)
        let vm = makeVM(words: ins(3, range) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runRotateTurret(host: Scripting.Host, encoded: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeRotateTurretStructure(host: host)
        let vm = makeVM(words: ins(3, encoded) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runGetDirection(host: Scripting.Host, encoded: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeGetDirectionStructure(host: host)
        let vm = makeVM(words: ins(3, encoded) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)
        return engine.returnValue
    }

    private func runStructureFire(host: Scripting.Host, targetEncoded: UInt16) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeFireStructure(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        engine.variables[2] = targetEncoded
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
