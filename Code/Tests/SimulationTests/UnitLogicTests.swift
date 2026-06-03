import DuneIIContracts
import DuneIIWorld
import Testing

@testable import DuneIISimulation

/// Behaviour parity for the Tier-B/C unit primitives. Expected values are hand-derived from the
/// OpenDUNE logic (`src/unit.c`) over the golden-verified `UnitInfo` table (e.g. tank `turningSpeed`
/// = 1, trike `movingSpeedFactor` = 45, harvester = 20, carryall = 200).
@Suite("Unit primitives (rotation / speed)")
struct UnitLogicTests {
    private let p: any UnitPrimitives = DefaultUnitPrimitives()
    private func unit(_ t: UnitType) -> Unit { var u = Unit(); u.o.type = UInt8(t.rawValue); return u }

    @Test("Unit_SetOrientation picks the shorter turn and the type's rotation speed")
    func setOrientation() {
        var u = unit(.tank)  // turningSpeed 1 → speed 4
        p.setOrientation(&u, orientation: 64, rotateInstantly: false, level: 0)
        #expect(u.orientation[0].target == 64)
        #expect(u.orientation[0].current == 0)
        #expect(u.orientation[0].speed == 4)  // diff 64 ≥ 0 → positive

        // Shorter turn is backwards → negative speed.
        u.orientation[0].current = 0
        p.setOrientation(&u, orientation: -56, rotateInstantly: false, level: 0)
        #expect(u.orientation[0].speed == -4)

        // Instant snap.
        p.setOrientation(&u, orientation: 50, rotateInstantly: true, level: 1)
        #expect(u.orientation[1].current == 50)
        #expect(u.orientation[1].target == 50)
        #expect(u.orientation[1].speed == 0)

        // Already aimed → no rotation.
        u.orientation[0].current = 64
        p.setOrientation(&u, orientation: 64, rotateInstantly: false, level: 0)
        #expect(u.orientation[0].speed == 0)
        #expect(u.orientation[0].current == 64)
    }

    @Test("Unit_Rotate steps toward the target and snaps on arrival")
    func rotate() {
        var u = unit(.tank)
        u.orientation[0].speed = 4; u.orientation[0].target = 64; u.orientation[0].current = 0
        p.rotate(&u, level: 0)
        #expect(u.orientation[0].current == 4)  // 0 + 4
        #expect(u.orientation[0].speed == 4)

        // Would overshoot → snap to target and stop.
        u.orientation[0].speed = 4; u.orientation[0].current = 62
        p.rotate(&u, level: 0)
        #expect(u.orientation[0].current == 64)
        #expect(u.orientation[0].speed == 0)

        // speed 0 → no-op.
        u.orientation[0].speed = 0; u.orientation[0].current = 10
        p.rotate(&u, level: 0)
        #expect(u.orientation[0].current == 10)

        // Negative-direction step wraps in int8.
        u.orientation[0].current = 0; u.orientation[0].target = Int8(truncatingIfNeeded: 200);
        u.orientation[0].speed = -4
        p.rotate(&u, level: 0)
        #expect(u.orientation[0].current == -4)
    }

    @Test("Unit_SetSpeed scales by movingSpeedFactor, game speed, and harvester load")
    func setSpeed() {
        // Trike (wheeled, movingSpeedFactor 45), normal game speed.
        var t = unit(.trike)
        p.setSpeed(&t, speed: 255, gameSpeed: 2)
        #expect(t.movingSpeed == 255)
        #expect(t.speed == 2)  // 45*255/256=44; 44>>4=2 ≠ 0
        #expect(t.speedPerTick == 255)  // speed≠0 ⇒ 255

        p.setSpeed(&t, speed: 16, gameSpeed: 2)
        #expect(t.movingSpeed == 16)
        #expect(t.speed == 1)  // 45*16/256=2; 2>>4=0 ⇒ speed 1
        #expect(t.speedPerTick == 32)  // 2<<4

        p.setSpeed(&t, speed: 0, gameSpeed: 2)
        #expect(t.movingSpeed == 0)
        #expect(t.speed == 0)
        #expect(t.speedPerTick == 0)

        p.setSpeed(&t, speed: 256, gameSpeed: 2)
        #expect(t.movingSpeed == 0)  // ≥ 256 ⇒ no movement

        // Harvester (movingSpeedFactor 20) — speed scaled by (255 - amount)/256.
        var h = unit(.harvester); h.amount = 128
        p.setSpeed(&h, speed: 255, gameSpeed: 2)
        #expect(h.movingSpeed == 126)  // 127*255/256
        #expect(h.speed == 1)  // 20*126/256=9; 9>>4=0 ⇒ 1
        #expect(h.speedPerTick == 144)  // 9<<4

        // Carryall (winger, movingSpeedFactor 200) — unaffected by game speed.
        var c = unit(.carryall)
        p.setSpeed(&c, speed: 255, gameSpeed: 4)
        #expect(c.movingSpeed == 255)
        #expect(c.speed == 12)  // 200*255/256=199; 199>>4=12
        #expect(c.speedPerTick == 255)
    }
}
