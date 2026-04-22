import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester → refinery refine step — Structures.refineSpiceStep")
struct HarvesterSpiceDepositTests {

    private let REFINERY: UInt8 = 12
    private let HARVESTER: UInt8 = 16
    private let TRIKE: UInt8 = 13
    private let WINDTRAP: UInt8 = 9

    /// Builds a scenario with a player-owned refinery + harvester
    /// docked with `amount` carried and `refineryHP` current HP.
    private func makeDockedPair(
        amount: UInt8,
        refineryHP: UInt16 = 450,
        harvesterHouse: UInt8 = Simulation.House.atreides
    ) -> (spool: Simulation.StructurePool, upool: Simulation.UnitPool, hpool: Simulation.HousePool, refIdx: Int, harIdx: Int) {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        let hIdx = hpool.allocate(at: Int(harvesterHouse))!
        var h = hpool[hIdx]
        h.credits = 100
        hpool[hIdx] = h

        let refIdx = spool.allocate(at: 5, type: REFINERY, houseID: harvesterHouse)!
        var ref = spool[refIdx]
        ref.hitpoints = refineryHP
        ref.state = Simulation.StructureState.ready.rawValue
        spool[refIdx] = ref

        let harIdx = upool.allocate(
            in: 16...19, type: HARVESTER, houseID: harvesterHouse
        )!
        var har = upool[harIdx]
        har.amount = amount
        har.inTransport = true
        upool[harIdx] = har

        return (spool, upool, hpool, refIdx, harIdx)
    }

    // MARK: Happy path

    @Test("Full-HP refinery + full harvester → drains 3, credits +21 (7 × 3)")
    func happyPath() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 100)
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 21)
        #expect(hpool[Int(Simulation.House.atreides)].credits == 121)
        #expect(upool[harIdx].amount == 97)
        #expect(upool[harIdx].inTransport == true)
    }

    @Test("Amount below step clamps — final tick drains 2 of 2 and clears inTransport")
    func drainToZeroClearsInTransport() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 2)
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 14)  // 7 × 2
        #expect(upool[harIdx].amount == 0)
        #expect(upool[harIdx].inTransport == false)
    }

    @Test("Zero-amount harvester returns 0 and clears inTransport without crediting")
    func zeroAmountIsNoOp() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 0)
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 0)
        #expect(hpool[Int(Simulation.House.atreides)].credits == 100)
        #expect(upool[harIdx].inTransport == false)
    }

    // MARK: HP scaling

    @Test("Half-HP refinery drains 1/tick (not 3) per OpenDUNE's int math")
    func halfHPReducesStep() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 100, refineryHP: 225)
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 7)
        #expect(upool[harIdx].amount == 99)
    }

    @Test("Heavily-damaged refinery (33% HP) drains 0 and returns 0")
    func lowHPStopsDrain() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 100, refineryHP: 150)
        let before = hpool[Int(Simulation.House.atreides)].credits
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 0)
        #expect(hpool[Int(Simulation.House.atreides)].credits == before)
        #expect(upool[harIdx].amount == 100)
    }

    // MARK: Rejection paths

    @Test("Wrong refinery type (WINDTRAP) rejects silently")
    func wrongRefineryTypeRejected() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        _ = hpool.allocate(at: Int(Simulation.House.atreides))
        let badIdx = spool.allocate(at: 5, type: WINDTRAP, houseID: Simulation.House.atreides)!
        let harIdx = upool.allocate(in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides)!
        var h = upool[harIdx]; h.amount = 50; upool[harIdx] = h
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: badIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 0)
        #expect(upool[harIdx].amount == 50)
    }

    @Test("Wrong unit type (TRIKE) rejects silently")
    func wrongHarvesterTypeRejected() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        _ = hpool.allocate(at: Int(Simulation.House.atreides))
        let refIdx = spool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var r = spool[refIdx]; r.hitpoints = 450; spool[refIdx] = r
        let trikeIdx = upool.allocateForType(type: TRIKE, houseID: Simulation.House.atreides)!
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: trikeIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 0)
    }

    @Test("Cross-house pair (Harkonnen harvester at Atreides refinery) rejects")
    func crossHouseRejected() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        _ = hpool.allocate(at: Int(Simulation.House.atreides))
        _ = hpool.allocate(at: Int(Simulation.House.harkonnen))
        let refIdx = spool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var r = spool[refIdx]; r.hitpoints = 450; spool[refIdx] = r
        let harIdx = upool.allocate(in: 16...19, type: HARVESTER, houseID: Simulation.House.harkonnen)!
        var h = upool[harIdx]; h.amount = 50; upool[harIdx] = h
        let before = hpool[Int(Simulation.House.atreides)].credits
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 0)
        #expect(hpool[Int(Simulation.House.atreides)].credits == before)
        #expect(upool[harIdx].amount == 50)
    }

    @Test("Out-of-range indices reject silently")
    func outOfRangeRejected() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        _ = hpool.allocate(at: Int(Simulation.House.atreides))
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: -1, harvesterIndex: 0,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 0)
        let gained2 = Simulation.Structures.refineSpiceStep(
            refineryIndex: 5, harvesterIndex: Simulation.UnitPool.capacity + 10,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained2 == 0)
    }

    // MARK: Enemy jitter

    @Test("Enemy harvester with jitter byte=0 → creditsStep = 7 + (0 % 4) - 1 = 6 → 18 gained")
    func enemyJitterMinimum() {
        // Atreides is player; Harkonnen is enemy here.
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        let harkIdx = hpool.allocate(at: Int(Simulation.House.harkonnen))!
        var hh = hpool[harkIdx]; hh.credits = 0; hpool[harkIdx] = hh
        let refIdx = spool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.harkonnen)!
        var r = spool[refIdx]; r.hitpoints = 450; spool[refIdx] = r
        let harIdx = upool.allocate(in: 16...19, type: HARVESTER, houseID: Simulation.House.harkonnen)!
        var h = upool[harIdx]; h.amount = 100; upool[harIdx] = h
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides,
            enemyJitterByte: { 0 }
        )
        // (7 + 0%4 - 1) × 3 = 6 × 3 = 18
        #expect(gained == 18)
    }

    @Test("Enemy harvester with jitter byte=3 → creditsStep = 7 + 2 = 9 → 27 gained")
    func enemyJitterMaximum() {
        var spool = Simulation.StructurePool()
        var upool = Simulation.UnitPool()
        var hpool = Simulation.HousePool()
        _ = hpool.allocate(at: Int(Simulation.House.harkonnen))
        let refIdx = spool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.harkonnen)!
        var r = spool[refIdx]; r.hitpoints = 450; spool[refIdx] = r
        let harIdx = upool.allocate(in: 16...19, type: HARVESTER, houseID: Simulation.House.harkonnen)!
        var h = upool[harIdx]; h.amount = 100; upool[harIdx] = h
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides,
            enemyJitterByte: { 3 }
        )
        #expect(gained == 27)
    }

    @Test("Player harvester ignores the jitter closure entirely")
    func playerIgnoresJitter() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 100)
        var callCount = 0
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides,
            enemyJitterByte: { callCount += 1; return 3 }
        )
        #expect(gained == 21)
        #expect(callCount == 0)
    }

    // MARK: Saturation

    @Test("Credits saturate at UInt16.max on overflow")
    func saturationOnOverflow() {
        var (spool, upool, hpool, refIdx, harIdx) = makeDockedPair(amount: 100)
        var h = hpool[Int(Simulation.House.atreides)]
        h.credits = UInt16.max - 5
        hpool[Int(Simulation.House.atreides)] = h
        let gained = Simulation.Structures.refineSpiceStep(
            refineryIndex: refIdx, harvesterIndex: harIdx,
            structures: spool, units: &upool, houses: &hpool,
            playerHouseID: Simulation.House.atreides
        )
        #expect(gained == 21)
        #expect(hpool[Int(Simulation.House.atreides)].credits == UInt16.max)
    }
}
