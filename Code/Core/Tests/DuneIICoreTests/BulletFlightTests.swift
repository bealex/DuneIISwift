import Foundation
import Testing
@testable import DuneIICore

@Suite("Bullet flight + arrival detonation via Scheduler.tickMovement")
struct BulletFlightTests {

    @Test("bullet spawned by Fire advances toward currentDestination each tick")
    func bulletAdvances() {
        let host = makeHost()
        // Shooter at (128,128), target at (3200,128) = tile (12, 0).
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128; tank.hitpoints = 200
        host.units[50] = tank

        // Spawn a bullet manually so we can pin the starting position.
        let bulletIdx = Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 23, houseID: 0, damage: 25,
            target: Scripting.EncodedIndex.tile(packed: 12).raw,
            host: host
        )
        #expect(bulletIdx != nil)
        let startX = host.units[bulletIdx!].positionX
        let startY = host.units[bulletIdx!].positionY
        #expect(host.units[bulletIdx!].speed == 255)

        // One tick advances the bullet's position.
        var scheduler = makeScheduler(host: host)
        scheduler.tick()
        let newX = host.units[bulletIdx!].positionX
        #expect(newX != startX || host.units[bulletIdx!].positionY != startY
                || !host.units[bulletIdx!].isUsed)
    }

    @Test("bullet detonates on arrival, spawning an explosion and freeing slot")
    func bulletDetonatesAtTarget() {
        let host = makeHost()
        // Target a tile very close so we arrive in a few ticks.
        _ = host.units.allocate(at: 50, type: 9, houseID: 0)
        var tank = host.units[50]
        tank.positionX = 128; tank.positionY = 128
        host.units[50] = tank

        // Put a target unit at (384, 128) that will absorb damage.
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 384; enemy.positionY = 128; enemy.hitpoints = 130
        enemy.seenByHouses = 0xFF
        host.units[30] = enemy

        let bulletIdx = Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 23, houseID: 0, damage: 25,
            target: Scripting.EncodedIndex.unit(30).raw,
            host: host
        )!
        // Stamp originEncoded as `Script_Unit_Fire` does.
        var bullet = host.units[bulletIdx]
        bullet.originEncoded = Scripting.EncodedIndex.unit(50).raw
        host.units[bulletIdx] = bullet

        // Run several ticks until the bullet reaches the target.
        var scheduler = makeScheduler(host: host)
        for _ in 0..<30 {
            scheduler.tick()
            if !host.units[bulletIdx].isUsed { break }
        }

        #expect(host.units[bulletIdx].isUsed == false, "bullet should have detonated")
        // Explosion queued in the pool.
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.count >= 1, "at least one explosion queued")
        // Explosion type = IMPACT_SMALL (BULLET's explosionType = 0).
        #expect(active[0].type == 0)
        // Target took damage.
        #expect(host.units[30].hitpoints < 130)
    }

    @Test("MISSILE_ROCKET bullet uses IMPACT_EXPLODE explosion type")
    func missileRocketExplosionType() {
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 7, houseID: 0) // LAUNCHER
        var launcher = host.units[50]
        launcher.positionX = 128; launcher.positionY = 128
        host.units[50] = launcher

        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 384; enemy.positionY = 128; enemy.hitpoints = 500
        enemy.seenByHouses = 0xFF
        host.units[30] = enemy

        let bulletIdx = Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 19, houseID: 0, damage: 75, // MISSILE_ROCKET
            target: Scripting.EncodedIndex.unit(30).raw,
            host: host
        )!
        var bullet = host.units[bulletIdx]
        bullet.originEncoded = Scripting.EncodedIndex.unit(50).raw
        host.units[bulletIdx] = bullet

        var scheduler = makeScheduler(host: host)
        for _ in 0..<30 {
            scheduler.tick()
            if !host.units[bulletIdx].isUsed { break }
        }

        #expect(host.units[bulletIdx].isUsed == false)
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.count >= 1)
        // MISSILE_ROCKET.explosionType = 3 (IMPACT_EXPLODE).
        #expect(active.contains(where: { $0.type == 3 }))
    }

    @Test("bullet with nil explosionType still frees slot (no visual pool entry for INVALID)")
    func bulletWithInvalidExplosion() {
        let host = makeHost()
        _ = host.units.allocate(at: 30, type: 15, houseID: 1)
        var enemy = host.units[30]
        enemy.positionX = 384; enemy.positionY = 128; enemy.hitpoints = 130
        enemy.seenByHouses = 0xFF
        host.units[30] = enemy

        // Spawn a SONIC_BLAST — explosionType is nil (EXPLOSION_INVALID).
        let bulletIdx = Simulation.Units.createBullet(
            position: Pos32(x: 128, y: 128),
            type: 24, houseID: 0, damage: 60,
            target: Scripting.EncodedIndex.unit(30).raw,
            host: host
        )!

        var scheduler = makeScheduler(host: host)
        for _ in 0..<30 {
            scheduler.tick()
            if !host.units[bulletIdx].isUsed { break }
        }
        #expect(host.units[bulletIdx].isUsed == false, "bullet still frees on arrival")
        // With invalid explosionType, makeExplosion early-outs and doesn't
        // queue a pool entry — damage also isn't applied.
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.isEmpty)
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

    private func makeScheduler(host: Scripting.Host) -> Simulation.Scheduler {
        let vm = Scripting.VM(
            program: Formats.Emc.Program.empty,
            functions: [Scripting.VM.Function?](repeating: nil, count: 64)
        )
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)
    }
}
