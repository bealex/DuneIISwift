import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester dock / undock — Structures.dockHarvester / undockHarvester")
struct HarvesterDockTests {

    private let REFINERY: UInt8 = 12
    private let HARVESTER: UInt8 = 16
    private let TRIKE: UInt8 = 13
    private let WINDTRAP: UInt8 = 9

    private func empty() -> (Simulation.StructurePool, Simulation.UnitPool) {
        (Simulation.StructurePool(), Simulation.UnitPool())
    }

    private func allocRefinery(
        at idx: Int, house: UInt8, hp: UInt16 = 450, pool: inout Simulation.StructurePool
    ) -> Int {
        let i = pool.allocate(at: idx, type: REFINERY, houseID: house)!
        var r = pool[i]
        r.hitpoints = hp
        r.state = Simulation.StructureState.idle.rawValue
        pool[i] = r
        return i
    }

    private func allocHarvester(
        house: UInt8, amount: UInt8, pool: inout Simulation.UnitPool
    ) -> Int {
        let i = pool.allocate(in: 16...19, type: HARVESTER, houseID: house)!
        var u = pool[i]
        u.amount = amount
        u.linkedID = 0xFF
        pool[i] = u
        return i
    }

    // MARK: Dock happy path

    @Test("Dock: refinery.linkedID captures harvester; harvester inTransport=true; refinery state→READY")
    func dockFirstHarvester() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let hIdx = allocHarvester(house: Simulation.House.atreides, amount: 100, pool: &u)
        #expect(Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &s, units: &u
        ))
        #expect(s[rIdx].linkedID == UInt8(hIdx))
        #expect(s[rIdx].state == Simulation.StructureState.ready.rawValue)
        #expect(u[hIdx].linkedID == 0xFF)  // first in chain
        #expect(u[hIdx].inTransport == true)
    }

    @Test("Dock a second harvester chains linkedIDs — prior head becomes new head's linkedID")
    func dockChaining() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let h1 = allocHarvester(house: Simulation.House.atreides, amount: 100, pool: &u)
        let h2 = allocHarvester(house: Simulation.House.atreides, amount: 100, pool: &u)
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: h1, structures: &s, units: &u
        )
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: h2, structures: &s, units: &u
        )
        #expect(s[rIdx].linkedID == UInt8(h2))
        #expect(u[h2].linkedID == UInt8(h1))  // h2 points back to h1
        #expect(u[h1].linkedID == 0xFF)
    }

    // MARK: Dock rejection

    @Test("Dock rejects non-refinery structure (WINDTRAP)")
    func dockRejectsNonRefinery() {
        var (s, u) = empty()
        let bad = s.allocate(at: 5, type: WINDTRAP, houseID: Simulation.House.atreides)!
        let hIdx = allocHarvester(house: Simulation.House.atreides, amount: 100, pool: &u)
        #expect(!Simulation.Structures.dockHarvester(
            refineryIndex: bad, harvesterIndex: hIdx, structures: &s, units: &u
        ))
        #expect(s[bad].linkedID == 0xFF)
        #expect(u[hIdx].inTransport == false)
    }

    @Test("Dock rejects non-harvester unit (TRIKE)")
    func dockRejectsNonHarvester() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let tIdx = u.allocateForType(type: TRIKE, houseID: Simulation.House.atreides)!
        #expect(!Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: tIdx, structures: &s, units: &u
        ))
        #expect(s[rIdx].linkedID == 0xFF)
    }

    @Test("Dock rejects cross-house pair")
    func dockRejectsCrossHouse() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let hIdx = allocHarvester(house: Simulation.House.harkonnen, amount: 100, pool: &u)
        #expect(!Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx, structures: &s, units: &u
        ))
    }

    // MARK: Undock happy path

    @Test("Undock: refinery unlinks, harvester moves to exit tile, state→IDLE")
    func undockSingleHarvester() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let hIdx = allocHarvester(house: Simulation.House.atreides, amount: 0, pool: &u)
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx, structures: &s, units: &u
        )
        let released = Simulation.Structures.undockHarvester(
            refineryIndex: rIdx, exitTile: (x: 30, y: 40),
            structures: &s, units: &u
        )
        #expect(released == hIdx)
        #expect(s[rIdx].linkedID == 0xFF)
        #expect(s[rIdx].state == Simulation.StructureState.idle.rawValue)
        #expect(u[hIdx].linkedID == 0xFF)
        #expect(u[hIdx].inTransport == false)
        #expect(u[hIdx].positionX == UInt16(30 * 256 + 128))
        #expect(u[hIdx].positionY == UInt16(40 * 256 + 128))
    }

    @Test("Undock with chain: refinery.linkedID becomes the next head; stays READY")
    func undockChainedHarvester() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let h1 = allocHarvester(house: Simulation.House.atreides, amount: 0, pool: &u)
        let h2 = allocHarvester(house: Simulation.House.atreides, amount: 0, pool: &u)
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: h1, structures: &s, units: &u
        )
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: h2, structures: &s, units: &u
        )
        // Head is h2; undocking pops it, exposing h1.
        let popped = Simulation.Structures.undockHarvester(
            refineryIndex: rIdx, exitTile: (x: 10, y: 10),
            structures: &s, units: &u
        )
        #expect(popped == h2)
        #expect(s[rIdx].linkedID == UInt8(h1))
        #expect(s[rIdx].state == Simulation.StructureState.ready.rawValue) // still chained
        #expect(u[h2].linkedID == 0xFF)
        #expect(u[h1].linkedID == 0xFF)  // original — never wrote to it
    }

    // MARK: Undock rejection

    @Test("Undock on refinery with no linked harvester returns nil")
    func undockEmptyChainReturnsNil() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let released = Simulation.Structures.undockHarvester(
            refineryIndex: rIdx, exitTile: (x: 10, y: 10),
            structures: &s, units: &u
        )
        #expect(released == nil)
        #expect(s[rIdx].linkedID == 0xFF)
    }

    @Test("Undock to off-map tile rejects; refinery untouched")
    func undockOffMapRejected() {
        var (s, u) = empty()
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let hIdx = allocHarvester(house: Simulation.House.atreides, amount: 0, pool: &u)
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx, structures: &s, units: &u
        )
        let released = Simulation.Structures.undockHarvester(
            refineryIndex: rIdx, exitTile: (x: 64, y: 10),
            structures: &s, units: &u
        )
        #expect(released == nil)
        #expect(s[rIdx].linkedID == UInt8(hIdx))  // still linked
    }

    // MARK: End-to-end with refineSpiceStep

    @Test("Full dock → repeated refineSpiceStep → undock empties harvester and releases it at exit")
    func endToEndCycle() {
        var (s, u) = empty()
        var h = Simulation.HousePool()
        let aIdx = h.allocate(at: Int(Simulation.House.atreides))!
        var hs = h[aIdx]; hs.credits = 0; h[aIdx] = hs
        let rIdx = allocRefinery(at: 5, house: Simulation.House.atreides, pool: &s)
        let hIdx = allocHarvester(house: Simulation.House.atreides, amount: 9, pool: &u)
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx, structures: &s, units: &u
        )
        // 3 ticks × 3 spice/tick = 9 drained
        var totalGained: UInt16 = 0
        for _ in 0..<3 {
            totalGained += Simulation.Structures.refineSpiceStep(
                refineryIndex: rIdx, harvesterIndex: hIdx,
                structures: s, units: &u, houses: &h,
                playerHouseID: Simulation.House.atreides
            )
        }
        // creditsStep(7) × 3 × 3 ticks = 63
        #expect(totalGained == 63)
        #expect(u[hIdx].amount == 0)
        #expect(u[hIdx].inTransport == false)
        // Now caller-decision: release harvester.
        let released = Simulation.Structures.undockHarvester(
            refineryIndex: rIdx, exitTile: (x: 20, y: 20),
            structures: &s, units: &u
        )
        #expect(released == hIdx)
        #expect(s[rIdx].state == Simulation.StructureState.idle.rawValue)
        #expect(u[hIdx].positionX == UInt16(20 * 256 + 128))
    }
}
