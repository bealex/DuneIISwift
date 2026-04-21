import Foundation
import Testing
@testable import DuneIICore

@Suite("Structure construction — state machine + tickConstruction (slice 4d-sim)")
struct StructureConstructionTests {

    private let CYARD: UInt8 = 8
    private let WINDTRAP: UInt8 = 9

    // MARK: StructureInfo.buildTime

    @Test("StructureInfo.buildTime table matches OpenDUNE values")
    func buildTimeTable() {
        let expected: [UInt16] = [
            16, 16, 130, 96, 144, 120, 120, 104, 80, 48,
            72, 120, 80, 80, 40, 64, 96, 48, 80
        ]
        for i in 0..<19 {
            #expect(Simulation.StructureInfo.table[i].buildTime == expected[i],
                    "type \(i) buildTime mismatch")
        }
    }

    // MARK: StructureState constants

    @Test("StructureState rawValues match OpenDUNE enum (-2, -1, 0, 1, 2)")
    func structureStateConstants() {
        #expect(Simulation.StructureState.detect.rawValue == -2)
        #expect(Simulation.StructureState.justBuilt.rawValue == -1)
        #expect(Simulation.StructureState.idle.rawValue == 0)
        #expect(Simulation.StructureState.busy.rawValue == 1)
        #expect(Simulation.StructureState.ready.rawValue == 2)
    }

    // MARK: startConstruction

    @Test("startConstruction on non-yard slot returns false; state unchanged")
    func startOnNonYard() {
        var pool = Simulation.StructurePool()
        _ = pool.allocate(at: 0, type: WINDTRAP, houseID: Simulation.House.atreides)
        let before = pool[0]
        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: WINDTRAP, pool: &pool
        )
        #expect(!ok)
        #expect(pool[0] == before)
    }

    @Test("startConstruction on out-of-range yardIndex returns false")
    func startOutOfRange() {
        var pool = Simulation.StructurePool()
        let ok = Simulation.Structures.startConstruction(
            yardIndex: 500, objectType: WINDTRAP, pool: &pool
        )
        #expect(!ok)
    }

    @Test("startConstruction with objectType >= 19 returns false")
    func startBadType() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: 19, pool: &pool
        )
        #expect(!ok)
    }

    @Test("startConstruction on IDLE yard flips to BUSY with countDown = buildTime << 8")
    func startValid() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        // create leaves state = JUSTBUILT; explicitly flip to IDLE to match
        // the "yard ready to build" state a scenario / save would present.
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot

        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: WINDTRAP, pool: &pool
        )
        #expect(ok)
        #expect(pool[0].state == Simulation.StructureState.busy.rawValue)
        #expect(pool[0].objectType == UInt16(WINDTRAP))
        // buildTime=48 × 256 = 12288.
        #expect(pool[0].countDown == 12288)
    }

    @Test("startConstruction on BUSY yard returns false; state unchanged")
    func startAlreadyBusy() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.objectType = 9
        slot.countDown = 1000
        pool[0] = slot

        let ok = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: 12 /* REFINERY */, pool: &pool
        )
        #expect(!ok)
        #expect(pool[0].objectType == 9)
        #expect(pool[0].countDown == 1000)
    }

    // MARK: tickConstruction

    @Test("tickConstruction on empty pool is a no-op")
    func tickEmpty() {
        var pool = Simulation.StructurePool()
        Simulation.Structures.tickConstruction(pool: &pool)
        // Nothing to assert — no allocation, no crash.
    }

    @Test("tickConstruction leaves IDLE yards untouched")
    func tickIdle() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot

        Simulation.Structures.tickConstruction(pool: &pool)
        #expect(pool[0].state == Simulation.StructureState.idle.rawValue)
        #expect(pool[0].countDown == 0)
    }

    @Test("tickConstruction decrements BUSY yard countDown by 256")
    func tickBusyDecrement() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.countDown = 12288
        pool[0] = slot

        Simulation.Structures.tickConstruction(pool: &pool)
        #expect(pool[0].state == Simulation.StructureState.busy.rawValue)
        #expect(pool[0].countDown == 12032)
    }

    @Test("tickConstruction flips BUSY→READY when countDown ≤ 256")
    func tickBusyFlipsReady() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.countDown = 256
        pool[0] = slot

        Simulation.Structures.tickConstruction(pool: &pool)
        #expect(pool[0].state == Simulation.StructureState.ready.rawValue)
        #expect(pool[0].countDown == 0)
    }

    @Test("tickConstruction: countDown small but positive → READY")
    func tickBusyFlipsReadyBelowStep() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.busy.rawValue
        slot.countDown = 100
        pool[0] = slot

        Simulation.Structures.tickConstruction(pool: &pool)
        #expect(pool[0].state == Simulation.StructureState.ready.rawValue)
        #expect(pool[0].countDown == 0)
    }

    @Test("tickConstruction leaves READY yards untouched (doesn't re-arm)")
    func tickReadyIdempotent() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.ready.rawValue
        slot.countDown = 0
        slot.objectType = 9
        pool[0] = slot

        Simulation.Structures.tickConstruction(pool: &pool)
        #expect(pool[0].state == Simulation.StructureState.ready.rawValue)
        #expect(pool[0].countDown == 0)
    }

    @Test("full 48-tick WINDTRAP build takes the yard IDLE → BUSY → READY")
    func fullWindtrapBuild() {
        var pool = Simulation.StructurePool()
        _ = Simulation.Structures.create(
            type: CYARD,
            houseID: Simulation.House.atreides,
            position: Pos32(x: 5 * 256, y: 5 * 256),
            pool: &pool
        )
        var slot = pool[0]
        slot.state = Simulation.StructureState.idle.rawValue
        pool[0] = slot

        _ = Simulation.Structures.startConstruction(
            yardIndex: 0, objectType: WINDTRAP, pool: &pool
        )
        #expect(pool[0].state == Simulation.StructureState.busy.rawValue)
        #expect(pool[0].countDown == 12288)

        // 48 ticks × 256 per tick = 12288 — exactly drains.
        for _ in 0..<48 {
            Simulation.Structures.tickConstruction(pool: &pool)
        }
        #expect(pool[0].state == Simulation.StructureState.ready.rawValue)
        #expect(pool[0].countDown == 0)
    }
}
