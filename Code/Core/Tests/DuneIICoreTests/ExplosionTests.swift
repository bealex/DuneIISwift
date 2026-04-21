import Foundation
import Testing
@testable import DuneIICore

@Suite("Explosions — ExplosionPool + makeExplosion + damage + slot 0x0E")
struct ExplosionTests {

    // MARK: ExplosionPool

    @Test("ExplosionPool.add fills slots sequentially and caps at 32")
    func poolAdd() {
        var pool = Simulation.ExplosionPool()
        for _ in 0..<32 {
            #expect(pool.add(type: 0, positionX: 0, positionY: 0) != nil)
        }
        #expect(pool.add(type: 0, positionX: 0, positionY: 0) == nil)
    }

    @Test("ExplosionPool.stopAtPosition frees active slots on matching tile")
    func poolStop() {
        var pool = Simulation.ExplosionPool()
        _ = pool.add(type: 0, positionX: 384, positionY: 128) // tile (1,0)
        _ = pool.add(type: 0, positionX: 2688, positionY: 128) // tile (10,0)
        pool.stopAtPosition(packed: 1) // y*64+x = 0*64+1 = 1
        #expect(pool.slots[0].isActive == false)
        #expect(pool.slots[1].isActive == true)
    }

    // MARK: applyUnitDamage / applyStructureDamage

    @Test("applyUnitDamage reduces HP; returns true on death and frees slot")
    func unitDamageDeath() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 0) // TANK
        var tank = host.units[30]
        tank.positionX = 128; tank.positionY = 128; tank.hitpoints = 50
        host.units[30] = tank

        let killed = Simulation.Explosions.applyUnitDamage(unitIndex: 30, damage: 50, host: host)
        #expect(killed == true)
        #expect(host.units[30].isUsed == false)
    }

    @Test("applyUnitDamage on wound leaves slot live")
    func unitDamageWound() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 0)
        var tank = host.units[30]
        tank.hitpoints = 200
        host.units[30] = tank

        let killed = Simulation.Explosions.applyUnitDamage(unitIndex: 30, damage: 30, host: host)
        #expect(killed == false)
        #expect(host.units[30].isUsed == true)
        #expect(host.units[30].hitpoints == 170)
    }

    @Test("applyUnitDamage ignores bullets (non-NormalUnit)")
    func unitDamageBulletInvulnerable() {
        let host = makeHost()
        _ = host.units.allocate(at: 12, type: 23, houseID: 0) // BULLET
        var bullet = host.units[12]
        bullet.hitpoints = 10
        host.units[12] = bullet

        let killed = Simulation.Explosions.applyUnitDamage(unitIndex: 12, damage: 100, host: host)
        #expect(killed == false)
        #expect(host.units[12].isUsed == true)
        #expect(host.units[12].hitpoints == 10) // unchanged
    }

    @Test("applyStructureDamage frees slot on zero HP")
    func structureDamageDeath() {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 12, houseID: 0) // REFINERY
        var s = host.structures[5]
        s.hitpoints = 100
        host.structures[5] = s

        let killed = Simulation.Explosions.applyStructureDamage(structureIndex: 5, damage: 100, host: host)
        #expect(killed == true)
        #expect(host.structures[5].isUsed == false)
    }

    @Test("applyStructureDamage damage=0 is a no-op returning false")
    func structureDamageZero() {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 12, houseID: 0)
        var s = host.structures[5]
        s.hitpoints = 100
        host.structures[5] = s

        let killed = Simulation.Explosions.applyStructureDamage(structureIndex: 5, damage: 0, host: host)
        #expect(killed == false)
        #expect(host.structures[5].hitpoints == 100)
    }

    // MARK: makeExplosion

    @Test("makeExplosion with hitpoints=0 skips damage but queues a pool entry")
    func explosionVisualOnly() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 1)
        var tank = host.units[30]
        tank.positionX = 128; tank.positionY = 128; tank.hitpoints = 200
        host.units[30] = tank

        Simulation.Explosions.makeExplosion(
            type: 0, position: Pos32(x: 128, y: 128),
            hitpoints: 0, unitOriginEncoded: 0, host: host
        )
        #expect(host.units[30].hitpoints == 200)
        #expect(host.explosions.slots[0].isActive)
        #expect(host.explosions.slots[0].type == 0)
    }

    @Test("makeExplosion radius damage: center unit takes full hitpoints")
    func explosionRadiusDirect() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 1)
        var tank = host.units[30]
        tank.positionX = 128; tank.positionY = 128; tank.hitpoints = 200
        host.units[30] = tank

        Simulation.Explosions.makeExplosion(
            type: 1, position: Pos32(x: 128, y: 128),
            hitpoints: 50, unitOriginEncoded: 0, host: host
        )
        // d = 0 → shift 0 → full damage.
        #expect(host.units[30].hitpoints == 150)
    }

    @Test("makeExplosion outside reactionDistance leaves unit untouched")
    func explosionRadiusFar() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 1)
        var tank = host.units[30]
        // distance = 16 tiles in pos32 = 4096. pos32 distance=4096, >>4 = 256 tiles-ish,
        // far beyond reactionDistance=16. Unit untouched.
        tank.positionX = 6144; tank.positionY = 128; tank.hitpoints = 200
        host.units[30] = tank

        Simulation.Explosions.makeExplosion(
            type: 1, position: Pos32(x: 128, y: 128),
            hitpoints: 100, unitOriginEncoded: 0, host: host
        )
        #expect(host.units[30].hitpoints == 200)
    }

    @Test("makeExplosion SANDWORM_SWALLOW spares sandworms")
    func explosionSwallowSparesSandworm() {
        let host = makeHost()
        _ = host.units.allocate(at: 16, type: 25, houseID: 0) // SANDWORM
        var worm = host.units[16]
        worm.positionX = 128; worm.positionY = 128; worm.hitpoints = 1000
        host.units[16] = worm

        Simulation.Explosions.makeExplosion(
            type: Simulation.ExplosionType.sandwormSwallow.rawValue,
            position: Pos32(x: 128, y: 128),
            hitpoints: 500, unitOriginEncoded: 0, host: host
        )
        #expect(host.units[16].hitpoints == 1000)
    }

    @Test("makeExplosion damages structure at the tile")
    func explosionStructureAtPoint() {
        let host = makeHost()
        _ = host.structures.allocate(at: 5, type: 12, houseID: 1) // REFINERY (3x2)
        var refinery = host.structures[5]
        refinery.positionX = 0; refinery.positionY = 0; refinery.hitpoints = 450
        host.structures[5] = refinery

        // Detonate at tile (1,0) — inside the 3x2 footprint.
        Simulation.Explosions.makeExplosion(
            type: 2, // IMPACT_LARGE
            position: Pos32(x: 384, y: 128),
            hitpoints: 100,
            unitOriginEncoded: 0, host: host
        )
        #expect(host.structures[5].hitpoints == 350)
    }

    @Test("makeExplosion with invalid type (>= 20) is a no-op")
    func explosionInvalidType() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 1)
        var tank = host.units[30]
        tank.positionX = 128; tank.positionY = 128; tank.hitpoints = 200
        host.units[30] = tank

        Simulation.Explosions.makeExplosion(
            type: 25, position: Pos32(x: 128, y: 128),
            hitpoints: 100, unitOriginEncoded: 0, host: host
        )
        #expect(host.units[30].hitpoints == 200)
        #expect(host.explosions.slots[0].isActive == false)
    }

    // MARK: explodeOnDeath

    @Test("applyUnitDamage spawns IMPACT_MEDIUM when a TANK dies")
    func explodeOnDeathTank() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 0) // TANK
        var tank = host.units[30]
        tank.positionX = 1024; tank.positionY = 768; tank.hitpoints = 50
        host.units[30] = tank

        let killed = Simulation.Explosions.applyUnitDamage(unitIndex: 30, damage: 50, host: host)
        #expect(killed == true)
        #expect(host.units[30].isUsed == false)
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.count == 1)
        // TANK.explosionType = 1 (IMPACT_MEDIUM).
        #expect(active[0].type == 1)
        // Explosion is at the unit's death position.
        #expect(active[0].positionX == 1024)
        #expect(active[0].positionY == 768)
    }

    @Test("applyUnitDamage does NOT explode infantry (explodeOnDeath=false)")
    func noExplodeOnDeathInfantry() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 2, houseID: 0) // INFANTRY
        var troops = host.units[30]
        troops.positionX = 128; troops.positionY = 128; troops.hitpoints = 10
        host.units[30] = troops

        let killed = Simulation.Explosions.applyUnitDamage(unitIndex: 30, damage: 50, host: host)
        #expect(killed == true)
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.isEmpty)
    }

    @Test("applyUnitDamage skips visual when explosionType is nil (e.g. harvester)")
    func noExplodeWhenInvalidType() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 16, houseID: 0) // HARVESTER
        var harv = host.units[30]
        harv.positionX = 128; harv.positionY = 128; harv.hitpoints = 5
        host.units[30] = harv

        let killed = Simulation.Explosions.applyUnitDamage(unitIndex: 30, damage: 100, host: host)
        #expect(killed == true)
        // HARVESTER has explodeOnDeath=true but explosionType=nil.
        // With nil the makeExplosion call is skipped entirely.
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.isEmpty)
    }

    // MARK: slot 0x0E (ExplosionSingle)

    @Test("slot 0x0E ExplosionSingle uses unit's max HP as radius damage")
    func scriptSlot0E() throws {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 9, houseID: 0) // TANK shooter
        var shooter = host.units[30]
        shooter.positionX = 128; shooter.positionY = 128; shooter.hitpoints = 50
        host.units[30] = shooter

        _ = host.units.allocate(at: 31, type: 15, houseID: 1) // enemy QUAD
        var enemy = host.units[31]
        enemy.positionX = 128; enemy.positionY = 128; enemy.hitpoints = 130
        host.units[31] = enemy

        host.currentObject = .unit(poolIndex: 30)

        var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
        functions[0] = Scripting.Functions.makeExplosionSingleUnit(host: host)
        // PUSH 1 (IMPACT_MEDIUM); FUNCTION 0.
        let vm = makeVM(words: ins(3, 1) + ins(14, 0), functions: functions)
        var engine = Scripting.Engine.reset()
        _ = vm.step(&engine); _ = vm.step(&engine)

        // TANK max HP = 200. Enemy at distance 0 → full 200 damage → dies.
        #expect(host.units[31].isUsed == false)
        // Explosion queued.
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.count == 1)
        #expect(active[0].type == 1)
    }

    // MARK: Scheduler tick on ExplosionPool

    @Test("Scheduler.tick decrements remainingFrames and frees on zero")
    func schedulerTicksExplosionLifetime() {
        let host = makeHost()
        _ = host.explosions.add(
            type: 0, positionX: 128, positionY: 128, frames: 3
        )
        #expect(host.explosions.slots[0].isActive)
        #expect(host.explosions.slots[0].remainingFrames == 3)

        let vm = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: [Scripting.VM.Function?](repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)
        scheduler.tick()
        #expect(host.explosions.slots[0].remainingFrames == 2)
        scheduler.tick()
        #expect(host.explosions.slots[0].remainingFrames == 1)
        scheduler.tick()
        // At remainingFrames == 1, next tick frees the slot.
        #expect(host.explosions.slots[0].isActive == false)
    }

    @Test("Scheduler.tick leaves inactive slots alone")
    func schedulerIgnoresInactiveExplosions() {
        let host = makeHost()
        let vm = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: [Scripting.VM.Function?](repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)
        scheduler.tick()
        for slot in host.explosions.slots {
            #expect(slot.isActive == false)
        }
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
