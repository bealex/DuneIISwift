import Foundation
import Testing
@testable import DuneIICore

@Suite("Firing — allocateForType + createBullet + slot 0x08")
struct FireTests {

    // MARK: UnitPool.allocateForType

    @Test("allocateForType: TANK finds first unused slot in 22..101")
    func allocateTankRange() {
        var pool = Simulation.UnitPool()
        // Pre-fill 22..25.
        for i in 22...25 {
            pool.allocate(at: i, type: 9, houseID: 0)
        }
        let slot = pool.allocateForType(type: 9, houseID: 1)
        #expect(slot == 26)
        #expect(pool.slots[26].type == 9)
        #expect(pool.slots[26].houseID == 1)
    }

    @Test("allocateForType: BULLET fits only in 12..15")
    func allocateBulletRange() {
        var pool = Simulation.UnitPool()
        let a = pool.allocateForType(type: 23, houseID: 0)
        let b = pool.allocateForType(type: 23, houseID: 0)
        let c = pool.allocateForType(type: 23, houseID: 0)
        let d = pool.allocateForType(type: 23, houseID: 0)
        let full = pool.allocateForType(type: 23, houseID: 0)
        #expect(a == 12)
        #expect(b == 13)
        #expect(c == 14)
        #expect(d == 15)
        #expect(full == nil)
    }

    @Test("allocateForType: invalid type returns nil")
    func allocateInvalidType() {
        var pool = Simulation.UnitPool()
        #expect(pool.allocateForType(type: 99, houseID: 0) == nil)
    }

    @Test("allocateForType: invalid house returns nil")
    func allocateInvalidHouse() {
        var pool = Simulation.UnitPool()
        #expect(pool.allocateForType(type: 9, houseID: 6) == nil)
        #expect(pool.allocateForType(type: 9, houseID: 0xFF) == nil)
    }

    // MARK: Simulation.Units.createBullet

    @Test("createBullet: invalid target returns nil")
    func createBulletInvalidTarget() {
        let host = makeHost()
        #expect(Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 23, houseID: 0, damage: 10,
            target: 0, host: host
        ) == nil)
        #expect(Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 23, houseID: 0, damage: 10,
            target: Scripting.EncodedIndex.unit(42).raw, // unallocated slot
            host: host
        ) == nil)
    }

    @Test("createBullet BULLET: allocates in 12..15 with correct fields")
    func createBulletBasic() {
        let host = makeHost()
        // Target unit at (2688, 128) = tile (10, 0).
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var target = host.units[30]
        target.positionX = 2688; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        let bulletIdx = Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 23, houseID: 0, damage: 10,
            target: Scripting.EncodedIndex.unit(30).raw,
            host: host
        )
        #expect(bulletIdx != nil)
        let idx = bulletIdx!
        #expect((12...15).contains(idx))
        let bullet = host.units[idx]
        #expect(bullet.type == 23)
        #expect(bullet.hitpoints == 10)
        #expect(bullet.targetAttack == Scripting.EncodedIndex.unit(30).raw)
        // Target position in currentDestination.
        #expect(bullet.currentDestinationX == 2688)
        #expect(bullet.currentDestinationY == 128)
        // Spawn position offset from shooter via the two MoveByDirection calls.
        // At orientation 64 (east), stepX=127 stepY=0, so x increases.
        #expect(bullet.positionX > 128)
    }

    @Test("createBullet MISSILE_ROCKET: spawns at shooter position with fireDelay")
    func createBulletMissile() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var target = host.units[30]
        target.positionX = 2688; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        let shooterPos = Pos32(x: 128, y: 128)
        let bulletIdx = Simulation.Units.createBullet(
            position: shooterPos,
            type: 19, houseID: 0, damage: 75,
            target: Scripting.EncodedIndex.unit(30).raw,
            host: host
        )
        #expect(bulletIdx != nil)
        let bullet = host.units[bulletIdx!]
        #expect(bullet.type == 19)
        // Missile spawn stays at shooter's position (no pre-step offset).
        #expect(bullet.positionX == 128)
        #expect(bullet.positionY == 128)
        // fireDelay = ui.fireDistance & 0xFF = 8.
        #expect(bullet.fireDelay == 8)
    }

    // MARK: Script_Unit_Fire (slot 0x08)

    @Test("slot 0x08 Fire: no target returns 0")
    func fireNoTarget() throws {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128
        host.units[50] = tank
        host.currentObject = .unit(poolIndex: 50)

        #expect(runFire(host: host) == 0)
    }

    @Test("slot 0x08 Fire: fireDelay > 0 returns 0 without firing")
    func fireOnCooldown() throws {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)

        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128
        tank.targetAttack = Scripting.EncodedIndex.unit(30).raw
        tank.fireDelay = 10
        host.units[50] = tank

        var target = host.units[30]
        target.positionX = 384; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        host.currentObject = .unit(poolIndex: 50)
        #expect(runFire(host: host) == 0)
        // No bullet in the 12..15 range.
        for i in 12...15 { #expect(!host.units[i].isUsed) }
    }

    @Test("slot 0x08 Fire: out-of-range target returns 0")
    func fireOutOfRange() throws {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)

        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128
        tank.targetAttack = Scripting.EncodedIndex.unit(30).raw
        tank.orientationCurrent = 64 // facing east
        host.units[50] = tank

        var target = host.units[30]
        // tile 20 = 5248 pos32. TANK fireDistance = 4 tiles = 1024.
        target.positionX = 5248; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        host.currentObject = .unit(poolIndex: 50)
        #expect(runFire(host: host) == 0)
    }

    @Test("slot 0x08 Fire: off-orientation target returns 0")
    func fireWrongOrientation() throws {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)

        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128
        tank.targetAttack = Scripting.EncodedIndex.unit(30).raw
        tank.orientationCurrent = 0 // facing NORTH — target is east
        host.units[50] = tank

        var target = host.units[30]
        target.positionX = 640; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        host.currentObject = .unit(poolIndex: 50)
        #expect(runFire(host: host) == 0)
    }

    @Test("slot 0x08 Fire: success spawns a bullet and resets fireDelay")
    func fireSuccess() throws {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)

        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128
        tank.targetAttack = Scripting.EncodedIndex.unit(30).raw
        tank.orientationCurrent = 64 // facing east
        tank.hitpoints = 200 // full HP so firesTwice path doesn't fire
        host.units[50] = tank

        var target = host.units[30]
        target.positionX = 640; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        host.currentObject = .unit(poolIndex: 50)
        #expect(runFire(host: host) == 1)

        // Bullet in 12..15.
        var bulletIdx: Int? = nil
        for i in 12...15 where host.units[i].isUsed {
            bulletIdx = i; break
        }
        #expect(bulletIdx != nil)
        let bullet = host.units[bulletIdx!]
        #expect(bullet.type == 23) // TANK fires BULLET
        #expect(bullet.originEncoded == Scripting.EncodedIndex.unit(50).raw)
        // TANK fireDelay = 80; * 2 = 160 clamps to 160. TANK has firesTwice=false;
        // wait — actually TANK has firesTwice=false per OpenDUNE (ID 9 has firesTwice=false).
        // Let me re-check with SIEGE_TANK which has firesTwice=true.
        let shooter = host.units[50]
        #expect(shooter.fireDelay == 160)
    }

    @Test("slot 0x08 Fire firesTwice: first fire sets quick reload, second fire the full reload")
    func fireFiresTwice() throws {
        let host = makeHost()
        // SIEGE_TANK (type 10, firesTwice=true, fireDelay=90).
        _ = host.units.allocate(at: 50, type: 10, houseID: 0)
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)

        var shooter = host.units[50]
        shooter.positionX = 128; shooter.positionY = 128
        shooter.targetAttack = Scripting.EncodedIndex.unit(30).raw
        shooter.orientationCurrent = 64
        shooter.hitpoints = 300 // > max/2 so firesTwice path is active
        host.units[50] = shooter

        var target = host.units[30]
        target.positionX = 640; target.positionY = 128; target.seenByHouses = 0xFF
        host.units[30] = target

        host.currentObject = .unit(poolIndex: 50)
        #expect(runFire(host: host) == 1)
        // First fire: flip=true, fireDelay = 5.
        #expect(host.units[50].fireTwiceFlip == true)
        #expect(host.units[50].fireDelay == 5)

        // Reset fireDelay to 0 to fire again.
        var after = host.units[50]
        after.fireDelay = 0
        host.units[50] = after

        #expect(runFire(host: host) == 1)
        // Second fire: flip=false, fireDelay = 90 * 2 = 180.
        #expect(host.units[50].fireTwiceFlip == false)
        #expect(host.units[50].fireDelay == 180)
    }

    @Test("scheduler tickFireCooldowns decrements each tick")
    func schedulerTicksFireDelay() {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        var tank = host.units[50]
        tank.fireDelay = 3
        host.units[50] = tank

        let vm = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: [Scripting.VM.Function?](repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)
        scheduler.tick()
        #expect(host.units[50].fireDelay == 2)
        scheduler.tick()
        #expect(host.units[50].fireDelay == 1)
        scheduler.tick()
        #expect(host.units[50].fireDelay == 0)
        // Does not underflow below 0.
        scheduler.tick()
        #expect(host.units[50].fireDelay == 0)
    }

    // MARK: Helpers

    private func makeHost() -> Scripting.Host {
        Scripting.Host(
            units: Simulation.UnitPool(),
            structures: Simulation.StructurePool(),
            playerHouseID: 0
        )
    }

    private func runFire(host: Scripting.Host) -> UInt16 {
        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeFireUnit(host: host)
        let vm = makeVM(words: ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
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
