import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester on-spice pickup — Units.harvestSpiceStep")
struct HarvestSpiceStepTests {

    private let HARVESTER: UInt8 = 16
    private let TRIKE: UInt8 = 13

    private func placeHarvester(
        at tile: (x: Int, y: Int), amount: UInt8, pool: inout Simulation.UnitPool
    ) -> Int {
        let i = pool.allocate(in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides)!
        var u = pool[i]
        u.positionX = UInt16(tile.x * 256 + 128)
        u.positionY = UInt16(tile.y * 256 + 128)
        u.amount = amount
        pool[i] = u
        return i
    }

    /// Script-driven RNG that returns each byte in sequence and wraps.
    /// Convenient to pin `Tools_Random_256` outputs.
    private final class ScriptedRNG {
        var bytes: [UInt8]
        var index: Int = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        func next() -> UInt8 {
            let b = bytes[index % bytes.count]
            index += 1
            return b
        }
    }

    // MARK: Happy path

    @Test("On spice tile: gains 1 (jitter=1) → amount+1, inTransport=true, no drain (gate!=0) → returns 1")
    func jitterOneNoDrain() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (5, 5), amount: 10, pool: &pool)
        let rng = ScriptedRNG([0x01, 0x01])  // jitter=1, drainGate=1 → no drain
        var drains: [(UInt16, Int16)] = []
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.spice.rawValue) },
            changeSpice: { packed, delta in drains.append((packed, delta)) },
            rng: { rng.next() }
        )
        #expect(ret == 1)
        #expect(pool[idx].amount == 11)
        #expect(pool[idx].inTransport == true)
        #expect(drains.isEmpty)
    }

    @Test("Jitter=0 on spice: amount unchanged, still sets inTransport, gate skip returns 1")
    func jitterZeroNoDrain() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (5, 5), amount: 10, pool: &pool)
        let rng = ScriptedRNG([0x00, 0x01])
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.spice.rawValue) },
            changeSpice: { _, _ in },
            rng: { rng.next() }
        )
        #expect(ret == 1)
        #expect(pool[idx].amount == 10)  // +0
        #expect(pool[idx].inTransport == true)
    }

    @Test("Drain gate 0 triggers tile -1 drain and returns 0")
    func drainTickReturnsZero() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (7, 8), amount: 10, pool: &pool)
        let rng = ScriptedRNG([0x01, 0x00])  // gate & 0x1F = 0 → drain
        var drains: [(UInt16, Int16)] = []
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.thickSpice.rawValue) },
            changeSpice: { p, d in drains.append((p, d)) },
            rng: { rng.next() }
        )
        #expect(ret == 0)
        #expect(drains.count == 1)
        #expect(drains[0].0 == UInt16(8 * 64 + 7))
        #expect(drains[0].1 == -1)
        #expect(pool[idx].amount == 11)
    }

    // MARK: Gates

    @Test("amount already at cap (100) returns 0 before touching RNG")
    func capGateEarlyReturn() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (5, 5), amount: 100, pool: &pool)
        var rngCalls = 0
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.spice.rawValue) },
            changeSpice: { _, _ in Issue.record("should not drain") },
            rng: { rngCalls += 1; return 0 }
        )
        #expect(ret == 0)
        #expect(rngCalls == 0)
        #expect(pool[idx].amount == 100)
    }

    @Test("Off-spice tile (normal sand) returns 0 without side effects")
    func offSpiceReturnsZero() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (5, 5), amount: 20, pool: &pool)
        var rngCalls = 0
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.normalSand.rawValue) },
            changeSpice: { _, _ in Issue.record("should not drain off-spice") },
            rng: { rngCalls += 1; return 0 }
        )
        #expect(ret == 0)
        #expect(rngCalls == 0)
        #expect(pool[idx].amount == 20)
        #expect(pool[idx].inTransport == false)
    }

    @Test("Wrong unit type (TRIKE) returns 0 immediately")
    func wrongTypeRejected() {
        var pool = Simulation.UnitPool()
        let idx = pool.allocateForType(type: TRIKE, houseID: Simulation.House.atreides)!
        var u = pool[idx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        pool[idx] = u
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.spice.rawValue) },
            changeSpice: { _, _ in Issue.record("unreachable") },
            rng: { 0 }
        )
        #expect(ret == 0)
        #expect(pool[idx].amount == 0)
    }

    @Test("Amount clamps at 100 even with jitter=1 from 100-adjacent values")
    func amountClampsAt100() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (5, 5), amount: 99, pool: &pool)
        let rng = ScriptedRNG([0x01, 0x01])  // jitter=1 brings 99→100; gate skips drain
        _ = Simulation.Units.harvestSpiceStep(
            harvesterIndex: idx, units: &pool,
            landscapeAt: { _ in UInt8(LandscapeType.spice.rawValue) },
            changeSpice: { _, _ in },
            rng: { rng.next() }
        )
        #expect(pool[idx].amount == 100)
    }

    @Test("Out-of-range index returns 0 without crash")
    func outOfRangeSafe() {
        var pool = Simulation.UnitPool()
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: -1, units: &pool,
            landscapeAt: { _ in 0 },
            changeSpice: { _, _ in },
            rng: { 0 }
        )
        #expect(ret == 0)
    }

    @Test("Off-map tile position returns 0 without landscape lookup")
    func offMapPositionSafe() {
        var pool = Simulation.UnitPool()
        let i = pool.allocate(in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides)!
        var u = pool[i]
        u.positionX = 0xFFFF
        u.positionY = 0xFFFF
        u.amount = 10
        pool[i] = u
        var lookups = 0
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: i, units: &pool,
            landscapeAt: { _ in lookups += 1; return UInt8(LandscapeType.spice.rawValue) },
            changeSpice: { _, _ in },
            rng: { 0 }
        )
        #expect(ret == 0)
        #expect(lookups == 0)
    }

    // MARK: Accumulation

    @Test("100 ticks: amount approaches cap, tile drains a few times")
    func accumulationOverTime() {
        var pool = Simulation.UnitPool()
        let idx = placeHarvester(at: (5, 5), amount: 0, pool: &pool)
        // Deterministic LCG-ish stream. Using ToolsRandom256 would add
        // entropy, but the test just verifies the cumulative math works.
        var seed: UInt32 = 0xDEADBEEF
        let next: () -> UInt8 = {
            seed = seed &* 1103515245 &+ 12345
            return UInt8(truncatingIfNeeded: seed >> 16)
        }
        var drainCount = 0
        for _ in 0..<400 {
            _ = Simulation.Units.harvestSpiceStep(
                harvesterIndex: idx, units: &pool,
                landscapeAt: { _ in UInt8(LandscapeType.spice.rawValue) },
                changeSpice: { _, _ in drainCount += 1 },
                rng: next
            )
        }
        #expect(pool[idx].amount == 100)
        // Cap-gate stops ticks from reaching the drain after fill, so
        // drainCount stays small.
        #expect(drainCount >= 1)
        #expect(drainCount < 50)
    }
}
