import Foundation
import Testing
@testable import DuneIICore

/// Port coverage for `Simulation.Tools.adjustToGameSpeed` + the
/// `Unit_SetSpeed` / `Unit_MovementTick` pipeline wiring.
/// Reference: OpenDUNE `src/tools.c:20` + `src/unit.c:1902,98`.
@Suite("Tools.adjustToGameSpeed + Unit_SetSpeed gameSpeed pipeline")
struct ToolsGameSpeedTests {

    private let HARVESTER: UInt8 = 16
    private let TANK: UInt8 = 9
    private let CARRYALL: UInt8 = 0 // MOVEMENT_WINGER (UnitInfo row 0)

    // MARK: adjustToGameSpeed — pure function coverage

    @Test("gameSpeed=2 is identity regardless of min/max/inverse")
    func normalSpeedIsIdentity() {
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 128, minimum: 1, maximum: 255,
            inverseSpeed: false, gameSpeed: 2
        ) == 128)
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 50, minimum: 1, maximum: 255,
            inverseSpeed: true, gameSpeed: 2
        ) == 50)
    }

    @Test("gameSpeed>4 also returns normal (OpenDUNE defensive branch)")
    func outOfRangeReturnsNormal() {
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 100, minimum: 1, maximum: 255,
            inverseSpeed: false, gameSpeed: 5
        ) == 100)
    }

    @Test("gameSpeed=0 clamps to minimum (after min = max(min, normal/2))")
    func slowestSpeedClampsToMinimum() {
        // normal=100, minimum=1 → clamped to 100/2 = 50. Switch case 0
        // returns the clamped minimum.
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 100, minimum: 1, maximum: 255,
            inverseSpeed: false, gameSpeed: 0
        ) == 50)
    }

    @Test("gameSpeed=4 clamps to maximum (after max = min(max, normal*2))")
    func fastestSpeedClampsToMaximum() {
        // normal=100, maximum=255 → clamped to 100*2 = 200. Switch
        // case 4 returns the clamped maximum.
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 100, minimum: 1, maximum: 255,
            inverseSpeed: false, gameSpeed: 4
        ) == 200)
    }

    @Test("gameSpeed=1 halfway between normal and minimum")
    func slowSpeedIsHalfway() {
        // normal - (normal - min)/2 with min clamped to 100/2=50:
        //   100 - (100-50)/2 = 100 - 25 = 75
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 100, minimum: 1, maximum: 255,
            inverseSpeed: false, gameSpeed: 1
        ) == 75)
    }

    @Test("gameSpeed=3 halfway between normal and maximum")
    func fastSpeedIsHalfway() {
        // normal + (max - normal)/2 with max clamped to 100*2=200:
        //   100 + (200-100)/2 = 150
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 100, minimum: 1, maximum: 255,
            inverseSpeed: false, gameSpeed: 3
        ) == 150)
    }

    @Test("inverseSpeed flips the bucket — slow at gameSpeed 4")
    func inverseFlipsBucket() {
        // inverseSpeed=true with gameSpeed=4 → bucket 0 → minimum.
        // normal=100 → min clamped to 50.
        #expect(Simulation.Tools.adjustToGameSpeed(
            normal: 100, minimum: 1, maximum: 255,
            inverseSpeed: true, gameSpeed: 4
        ) == 50)
    }

    // MARK: Unit_SetSpeed — gameSpeed path

    private func tank(gameSpeed: UInt8, speedPercent: UInt16 = 255)
        -> Simulation.UnitSlot
    {
        var pool = Simulation.UnitPool()
        let idx = pool.allocateForType(
            type: TANK, houseID: Simulation.House.atreides
        )!
        Simulation.Units.setSpeed(
            poolIndex: idx, speedPercent: speedPercent,
            units: &pool, gameSpeed: gameSpeed
        )
        return pool[idx]
    }

    @Test("TANK at gameSpeed=2 matches pre-port expected split")
    func tankAtNormalSpeed() {
        // TANK movingSpeedFactor = 25 (UnitInfo row 9).
        // speed = 25 * 255 / 256 = 24.
        // At gameSpeed=2 adjust is identity.
        // High nibble 1 (24>>4) → clamp=1, speedPerTick pinned to 255.
        let u = tank(gameSpeed: 2)
        #expect(u.speed == 1)
        #expect(u.speedPerTick == 255)
        #expect(u.movingSpeed == 255)
    }

    @Test("TANK at gameSpeed=0 slower than gameSpeed=2")
    func tankAtSlowestIsSlower() {
        let normal = tank(gameSpeed: 2)
        let slow = tank(gameSpeed: 0)
        // adjust(24, min=1, max=255, gameSpeed=0):
        //   min clamps up to 24/2=12, max clamps down to 24*2=48.
        //   case 0 returns minimum = 12.
        //   speedPerTick = 12<<4 = 192; high nibble 0 → clamp=1, no
        //   255-pin → speedPerTick stays 192.
        #expect(slow.speed == 1)
        #expect(slow.speedPerTick == 192)
        #expect(slow.speedPerTick < normal.speedPerTick)
    }

    @Test("TANK at gameSpeed=4 faster than gameSpeed=2 and crosses nibble")
    func tankAtFastestCrossesNibble() {
        let fast = tank(gameSpeed: 4)
        // adjust(24, min=1, max=255, gameSpeed=4):
        //   min=12, max=48. case 4 returns maximum = 48.
        //   speedPerTick = 48<<4 = 768; clamp = 48>>4 = 3.
        //   clamp != 0 → speedPerTick pinned to 255, speed = 3.
        #expect(fast.speed == 3)
        #expect(fast.speedPerTick == 255)
    }

    @Test("CARRYALL (winger) ignores gameSpeed")
    func wingerBypassesGameSpeed() {
        var pool = Simulation.UnitPool()
        let idx = pool.allocateForType(
            type: CARRYALL, houseID: Simulation.House.atreides
        )!
        Simulation.Units.setSpeed(
            poolIndex: idx, speedPercent: 255,
            units: &pool, gameSpeed: 0
        )
        let slow = pool[idx]
        pool = Simulation.UnitPool()
        let idx2 = pool.allocateForType(
            type: CARRYALL, houseID: Simulation.House.atreides
        )!
        Simulation.Units.setSpeed(
            poolIndex: idx2, speedPercent: 255,
            units: &pool, gameSpeed: 4
        )
        let fast = pool[idx2]
        #expect(slow.speed == fast.speed)
        #expect(slow.speedPerTick == fast.speedPerTick)
        #expect(slow.movingSpeed == fast.movingSpeed)
    }

    // MARK: Scheduler.tickMovement — gameSpeed applied to accumulator

    private func scheduler() -> Simulation.Scheduler {
        let host = Scripting.Host(
            landscapeAt: { _ in UInt8(LandscapeType.normalSand.rawValue) },
            spiceMap: nil
        )
        let empty = Formats.Emc.Program.empty
        let vm = Scripting.VM(
            program: empty, functions: Array(repeating: nil, count: 64)
        )
        return Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm
        )
    }

    @Test("Ground unit at gameSpeed=0 advances slower per tick than at gameSpeed=2")
    func groundGameSpeedDrivesAccumulator() {
        // Drive two identical TANKs under different Scheduler.gameSpeed
        // values and compare total distance after N ticks.
        func distanceAfterTicks(_ gs: UInt8) -> Int {
            var s = scheduler()
            s.gameSpeed = gs
            let idx = s.host.units.allocateForType(
                type: TANK, houseID: Simulation.House.atreides
            )!
            var u = s.host.units[idx]
            u.hitpoints = 200
            u.positionX = UInt16(10 * 256 + 128)
            u.positionY = UInt16(10 * 256 + 128)
            s.host.units[idx] = u
            Simulation.Units.setSpeed(
                poolIndex: idx, speedPercent: 255,
                units: &s.host.units, gameSpeed: gs
            )
            Simulation.Units.orderMove(
                poolIndex: idx, tileX: 30, tileY: 10,
                units: &s.host.units
            )
            let startX = Int(s.host.units[idx].positionX)
            for _ in 0..<30 { s.tick() }
            return Int(s.host.units[idx].positionX) - startX
        }
        let slow = distanceAfterTicks(0)
        let normal = distanceAfterTicks(2)
        let fast = distanceAfterTicks(4)
        #expect(slow < normal)
        #expect(normal < fast)
    }

    @Test("Winger movement ignores Scheduler.gameSpeed")
    func wingerAccumulatorIgnoresGameSpeed() {
        func distanceAfterTicks(_ gs: UInt8) -> Int {
            var s = scheduler()
            s.gameSpeed = gs
            let idx = s.host.units.allocateForType(
                type: CARRYALL, houseID: Simulation.House.atreides
            )!
            var u = s.host.units[idx]
            u.hitpoints = 100
            u.positionX = UInt16(10 * 256 + 128)
            u.positionY = UInt16(10 * 256 + 128)
            s.host.units[idx] = u
            // Wingers bypass gameSpeed in setSpeed — the value we pass
            // here is ignored by the function for winger types. Left
            // as 2 for clarity.
            Simulation.Units.setSpeed(
                poolIndex: idx, speedPercent: 255,
                units: &s.host.units, gameSpeed: 2
            )
            u = s.host.units[idx]
            // Set targetMove directly so tickMovement drives the
            // fallback-slide accumulator path (unit scripts are empty
            // here, so no CalculateRoute runs).
            let packed: UInt16 = (10 &<< 6) | 30
            u.targetMove = Scripting.EncodedIndex.tile(packed: packed).raw
            s.host.units[idx] = u
            let startX = Int(s.host.units[idx].positionX)
            for _ in 0..<10 { s.tick() }
            return Int(s.host.units[idx].positionX) - startX
        }
        #expect(distanceAfterTicks(0) == distanceAfterTicks(4))
    }
}
