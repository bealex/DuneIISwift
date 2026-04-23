import Foundation
import Testing
@testable import DuneIICore

/// STARPORT slice 5b — `commitStarportOrder` + the scheduler's
/// `tickStarportDelivery` / `tickStarportAvailability` passes. Verifies
/// that ordering CHOAM units decrements the stock, chains units onto
/// the house, ticks the frigate countdown to a FRIGATE spawn, and
/// handles the "random stock bump" refresh.
///
/// Reference: `src/house.c:101..115` (availability bump),
/// `src/house.c:219..258` (delivery tick), and
/// `src/structure.c:1583..1632` (order commit).
@Suite("STARPORT — order commit + delivery + availability bump")
struct StarportDeliveryTests {

    private let STARPORT: UInt8 = 11
    private let FRIGATE: UInt8 = 26
    private let TANK_TYPE: UInt8 = 9
    private let TRIKE_TYPE: UInt8 = 13

    private func scheduler() -> Simulation.Scheduler {
        let host = Scripting.Host(spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm, teamVM: vm)
    }

    // MARK: - commitStarportOrder

    @Test("commitStarportOrder chains 2 units, decrements stock, kicks timer")
    func commitChainsAndDecrements() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE_TYPE)] = 5
        let chained = Simulation.Structures.commitStarportOrder(
            houseID: Simulation.House.atreides,
            orders: [(typeID: TRIKE_TYPE, count: 2)],
            houses: &s.host.houses,
            units: &s.host.units,
            stock: &stock,
            deliveryTime: 10
        )
        #expect(chained == 2)
        #expect(stock[Int(TRIKE_TYPE)] == 3)
        let h = s.host.houses[Int(Simulation.House.atreides)]
        #expect(h.starportLinkedID != Simulation.HousePool.invalidIndex,
                "chain head must be set after order commit")
        #expect(h.starportTimeLeft == 10)
        // Two units allocated with type=TRIKE.
        let trikeCount = s.host.units.slots.filter { $0.isUsed && $0.type == TRIKE_TYPE }.count
        #expect(trikeCount == 2)
    }

    @Test("commitStarportOrder clamps stock to -1 when the last unit of a type is ordered")
    func commitClampsStockToMinusOne() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TANK_TYPE)] = 1
        _ = Simulation.Structures.commitStarportOrder(
            houseID: Simulation.House.atreides,
            orders: [(typeID: TANK_TYPE, count: 1)],
            houses: &s.host.houses,
            units: &s.host.units,
            stock: &stock,
            deliveryTime: 10
        )
        #expect(stock[Int(TANK_TYPE)] == -1,
                "stock draining to 0 should snap to -1 (OpenDUNE parity)")
    }

    @Test("commitStarportOrder builds a valid linked-ID chain (each unit's linkedID points to the prior head)")
    func commitBuildsLinkedChain() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE_TYPE)] = 5
        _ = Simulation.Structures.commitStarportOrder(
            houseID: Simulation.House.atreides,
            orders: [(typeID: TRIKE_TYPE, count: 3)],
            houses: &s.host.houses,
            units: &s.host.units,
            stock: &stock,
            deliveryTime: 10
        )
        // Walk from the head — 3 hops then the final linkedID is 0xFF.
        let h = s.host.houses[Int(Simulation.House.atreides)]
        var cur = Int(h.starportLinkedID)
        var visited = 0
        while cur != 0xFF, visited < 10 {
            let u = s.host.units[cur]
            #expect(u.isUsed, "chained unit at \(cur) should be allocated")
            #expect(u.inTransport, "chained unit should be inTransport=true")
            visited += 1
            cur = Int(u.linkedID)
        }
        #expect(visited == 3, "expected to visit 3 chained units, visited \(visited)")
    }

    @Test("commitStarportOrder returns 0 when no houses are allocated")
    func commitNoHousesReturnsZero() {
        var s = scheduler()
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TANK_TYPE)] = 5
        let chained = Simulation.Structures.commitStarportOrder(
            houseID: Simulation.House.atreides,
            orders: [(typeID: TANK_TYPE, count: 1)],
            houses: &s.host.houses,
            units: &s.host.units,
            stock: &stock,
            deliveryTime: 10
        )
        #expect(chained == 0)
        #expect(stock[Int(TANK_TYPE)] == 5, "stock must not mutate if no units chained")
    }

    // MARK: - tickStarportDelivery

    @Test("tickStarportDelivery decrements the timer each cadence tick")
    func deliveryTimerDecrements() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        var h = s.host.houses[Int(Simulation.House.atreides)]
        h.starportLinkedID = 50          // non-invalid chain head
        h.starportTimeLeft = 5
        s.host.houses[Int(Simulation.House.atreides)] = h

        s.tickStarportDelivery()
        #expect(s.host.houses[Int(Simulation.House.atreides)].starportTimeLeft == 4)
        s.tickStarportDelivery()
        s.tickStarportDelivery()
        #expect(s.host.houses[Int(Simulation.House.atreides)].starportTimeLeft == 2)
    }

    @Test("tickStarportDelivery skips houses with no pending order")
    func deliverySkipsEmptyQueue() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        var h = s.host.houses[Int(Simulation.House.atreides)]
        h.starportLinkedID = Simulation.HousePool.invalidIndex
        h.starportTimeLeft = 5
        s.host.houses[Int(Simulation.House.atreides)] = h
        s.tickStarportDelivery()
        // Timer untouched because no chain head.
        #expect(s.host.houses[Int(Simulation.House.atreides)].starportTimeLeft == 5)
    }

    @Test("tickStarportDelivery spawns a FRIGATE when countdown hits 0 and a STARPORT exists")
    func deliverySpawnsFrigate() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        // Place a STARPORT at (10, 10) owned by Atreides.
        let sIdx = s.host.structures.allocate(
            at: 0, type: STARPORT, houseID: Simulation.House.atreides
        )!
        var structSlot = s.host.structures[sIdx]
        structSlot.positionX = UInt16(10 * 256)
        structSlot.positionY = UInt16(10 * 256)
        structSlot.linkedID = 0xFF
        s.host.structures[sIdx] = structSlot

        // Pre-allocate one "cargo" unit (slot 30 is inside the trike
        // indexStart..End range so allocateForType won't collide).
        var h = s.host.houses[Int(Simulation.House.atreides)]
        h.starportLinkedID = 30         // pretend this unit is the chain head
        h.starportTimeLeft = 1           // one tick until arrival
        s.host.houses[Int(Simulation.House.atreides)] = h

        s.tickStarportDelivery()        // countdown → 0 → spawn
        // Frigate exists now.
        let frigates = s.host.units.slots.filter { $0.isUsed && $0.type == self.FRIGATE }
        #expect(frigates.count == 1, "expected 1 FRIGATE spawn, got \(frigates.count)")
        let fidx = frigates.first.map { Int($0.index) }!
        #expect(s.host.units[fidx].linkedID == 30,
                "frigate must carry the chain head as its cargo")
        #expect(s.host.units[fidx].inTransport)
        // Chain head cleared on the house.
        let afterH = s.host.houses[Int(Simulation.House.atreides)]
        #expect(afterH.starportLinkedID == Simulation.HousePool.invalidIndex)
        #expect(afterH.starportTimeLeft == 10, "timer re-seeds on successful spawn")
    }

    @Test("tickStarportDelivery resets timer to 1 when no STARPORT is available")
    func deliveryRetriesWhenNoStarport() {
        var s = scheduler()
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        var h = s.host.houses[Int(Simulation.House.atreides)]
        h.starportLinkedID = 30
        h.starportTimeLeft = 1
        s.host.houses[Int(Simulation.House.atreides)] = h

        s.tickStarportDelivery()
        // No FRIGATE created; timer re-seeded to 1 (retry).
        let frigates = s.host.units.slots.filter { $0.isUsed && $0.type == self.FRIGATE }
        #expect(frigates.count == 0)
        let afterH = s.host.houses[Int(Simulation.House.atreides)]
        #expect(afterH.starportLinkedID == 30, "chain preserved for next retry")
        #expect(afterH.starportTimeLeft == 1)
    }

    // MARK: - tickStarportAvailability

    @Test("tickStarportAvailability bumps -1 → 1 for a listed unit type")
    func availabilityBumpsMinusOneToOne() {
        let host = Scripting.Host(spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        // Force rng to always return the TANK type index so the bump lands there.
        var s = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { UInt8(self.TANK_TYPE) }
        )
        s.starportStock[Int(TANK_TYPE)] = -1
        s.tickStarportAvailability()
        #expect(s.starportStock[Int(TANK_TYPE)] == 1,
                "-1 stock must bump to 1 on first availability tick")
    }

    @Test("tickStarportAvailability increments listed stock up to the cap of 10")
    func availabilityIncrementsToCap() {
        let host = Scripting.Host(spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var s = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { UInt8(self.TRIKE_TYPE) }
        )
        s.starportStock[Int(TRIKE_TYPE)] = 3
        s.tickStarportAvailability()
        #expect(s.starportStock[Int(TRIKE_TYPE)] == 4)
        // Cap test: stock already 10 → no change.
        s.starportStock[Int(TRIKE_TYPE)] = 10
        s.tickStarportAvailability()
        #expect(s.starportStock[Int(TRIKE_TYPE)] == 10,
                "stock >= 10 must not increment past cap")
    }

    @Test("tickStarportAvailability leaves stock=0 alone (type is simply not for sale)")
    func availabilitySkipsZeroStock() {
        let host = Scripting.Host(spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var s = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { UInt8(self.TANK_TYPE) }
        )
        s.starportStock[Int(TANK_TYPE)] = 0
        s.tickStarportAvailability()
        #expect(s.starportStock[Int(TANK_TYPE)] == 0)
    }

    @Test("tickStarportAvailability is a no-op without an RNG (harvestRNG = nil)")
    func availabilityNoOpWithoutRNG() {
        var s = scheduler()   // harvestRNG defaults to nil
        s.starportStock[Int(TANK_TYPE)] = 5
        s.tickStarportAvailability()
        #expect(s.starportStock[Int(TANK_TYPE)] == 5)
    }
}
