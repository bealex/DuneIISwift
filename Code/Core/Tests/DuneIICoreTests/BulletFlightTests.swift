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
        // Post-setSpeed port: a 255-percent bullet gets speed=15
        // (tile-hop clamp) + speedPerTick=255 (accumulator pegged).
        // The old direct-write `speed = 255` is no longer the shape.
        #expect(host.units[bulletIdx!].speed == 15)
        #expect(host.units[bulletIdx!].speedPerTick == 255)

        // OpenDUNE's subpixel accumulator takes 2 ticks to cross 255
        // (first tick lands remainder=255, second overflows and moves).
        // Run 3 so we guarantee ≥1 step regardless of starting remainder.
        var scheduler = makeScheduler(host: host)
        for _ in 0..<3 { scheduler.tick() }
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

    @Test("createBullet aimed at a multi-tile structure uses layout-adjusted centre for direction (Tools_Index_GetTile parity)")
    func createBulletUsesStructureLayoutCentre() {
        // CYARD (type 8, layout s2x2) at anchor (7680, 6400). OpenDUNE's
        // `Unit_CreateBullet` (`src/unit.c:1962`) uses
        // `Tools_Index_GetTile(target)` which returns anchor +
        // layoutTileDiff — for s2x2 that's anchor + (0x100, 0x100) =
        // (7936, 6656). Orientation from (7740, 6820) to layout centre
        // ≈ NE (32). Using raw anchor (7680, 6400) would give ~N-NE
        // (~8-12), so the bullet flies toward the CYARD's NW corner
        // instead of its body.
        let host = makeHost()
        // Place the CYARD.
        _ = host.structures.allocate(at: 0, type: 8, houseID: 1)
        var s = host.structures[0]
        s.positionX = 7680
        s.positionY = 6400
        host.structures[0] = s

        // Shooter stamp — not strictly required for createBullet but
        // makes `originEncoded` consistent.
        _ = host.units.allocate(at: 50, type: 4, houseID: 2) // SOLDIER, enemy
        var sh = host.units[50]
        sh.positionX = 7740
        sh.positionY = 6820
        host.units[50] = sh

        let bulletIdx = Simulation.Units.createBullet(
            position: Pos32(x: 7740, y: 6820),
            type: 23, houseID: 2, damage: 3,
            target: Scripting.EncodedIndex.structure(0).raw,
            host: host
        )!
        let bullet = host.units[bulletIdx]
        // Orientation should be ~32 (NE) for a layout-centre target, not
        // ~8 (roughly N) which is what the raw anchor would give.
        let o = Int(bullet.orientationCurrent)
        #expect((o == 32) || (24...36).contains(o),
                "bullet orientation should reflect heading to structure's layout-adjusted centre (NE), got \(o)")
        // currentDestination also uses the centre.
        #expect(bullet.currentDestinationX == 7936)
        #expect(bullet.currentDestinationY == 6656)
    }

    @Test("bullet stepping onto LST_STRUCTURE tile detonates mid-flight (src/unit.c:1409..1416)")
    func bulletDetonatesOnStructureTile() {
        // Port of `Unit_Move`'s `type == LST_WALL || LST_STRUCTURE ||
        // LST_ENTIRELY_MOUNTAIN` branch: a UNIT_BULLET stepping into a
        // structure tile explodes at its new position and frees, even
        // if its `currentDestination` is further along. Without this,
        // a SOLDIER's bullet aimed at a 2x2 CYARD's layout-centre
        // (one tile past the nearest edge) misses the
        // `distance < 16` arrival gate and keeps flying until it
        // clips through the structure — in SAVE007 that delayed u12's
        // impact by 3 ticks and left CYARD undamaged at tick 586.
        let host = makeHost()
        _ = host.units.allocate(at: 50, type: 4, houseID: 0)  // SOLDIER shooter
        var shooter = host.units[50]
        shooter.positionX = 7651
        shooter.positionY = 6941
        host.units[50] = shooter

        // Mark tile (30, 25) as LST_STRUCTURE via host.landscapeAt.
        // Packed = 25*64 + 30 = 1630. The bullet steps NE from
        // ~(7740, 6820) toward (7936, 6656); one winger-speed step
        // lands at ~(7907, 6653) which is tile (30, 25).
        host.landscapeAt = { packed in
            if packed == 1630 {
                return UInt8(LandscapeType.structure.rawValue)
            }
            return UInt8(LandscapeType.normalSand.rawValue)
        }

        // Allocate a bullet at the pre-impact position (mid-flight
        // snapshot).
        _ = host.units.allocate(at: 12, type: 23, houseID: 0)
        var bullet = host.units[12]
        bullet.positionX = 7740
        bullet.positionY = 6820
        bullet.currentDestinationX = 7936
        bullet.currentDestinationY = 6656
        bullet.orientationCurrent = 32
        bullet.orientationTarget = 32
        bullet.movingSpeed = 255
        bullet.speed = 15
        bullet.speedPerTick = 255
        bullet.speedRemainder = 255
        bullet.hitpoints = 3
        bullet.distanceToDestination = 0x7FFF
        bullet.originEncoded = Scripting.EncodedIndex.unit(50).raw
        host.units[12] = bullet

        var scheduler = makeScheduler(host: host)
        scheduler.perTickCadenceGatesEnabled = true
        // Step a handful of times; the structure-collision detonation
        // should fire as soon as the winger step crosses into tile
        // (30, 25).
        for _ in 0..<30 {
            scheduler.tick()
            if !host.units[12].isUsed { break }
        }
        #expect(host.units[12].isUsed == false,
                "bullet must detonate on structure-tile entry")
        let active = host.explosions.slots.filter(\.isActive)
        #expect(active.count >= 1, "explosion queued at structure-tile detonation")
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
