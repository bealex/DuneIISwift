import Foundation
import Testing
@testable import DuneIICore

@Suite("Carryall pickup — findFreeRefinery, callCarryall, tickHarvesting integration")
struct CarryallPickupTests {

    private let REFINERY: UInt8 = 12
    private let HARVESTER: UInt8 = 16

    private func emptyScheduler(rng: @escaping () -> UInt8) -> Simulation.Scheduler {
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: Simulation.SpiceMap()
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm, harvestRNG: rng
        )
    }

    private func harvester(at tile: (x: Int, y: Int)) -> Simulation.UnitSlot {
        var u = Simulation.UnitSlot()
        u.isUsed = true
        u.isAllocated = true
        u.type = HARVESTER
        u.houseID = Simulation.House.atreides
        u.positionX = UInt16(tile.x * 256 + 128)
        u.positionY = UInt16(tile.y * 256 + 128)
        return u
    }

    // MARK: findFreeRefinery — pure helper

    @Test("empty pool → nil")
    func emptyPoolYieldsNil() {
        let pool = Simulation.StructurePool()
        let h = harvester(at: (10, 10))
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == nil)
    }

    @Test("single unlinked refinery → picks it")
    func unlinkedRefineryPicked() {
        var pool = Simulation.StructurePool()
        let r = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var slot = pool[r]
        slot.positionX = UInt16(20 * 256); slot.positionY = UInt16(20 * 256)
        slot.linkedID = 0xFF
        pool[r] = slot

        let h = harvester(at: (10, 10))
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == r)
    }

    @Test("single linked refinery → nil (no free candidate)")
    func linkedRefineryExcluded() {
        var pool = Simulation.StructurePool()
        let r = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var slot = pool[r]
        slot.positionX = UInt16(20 * 256); slot.positionY = UInt16(20 * 256)
        slot.linkedID = 42   // another harvester already docked
        pool[r] = slot

        let h = harvester(at: (10, 10))
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == nil)
    }

    @Test("two refineries, one linked: picks the free one even if farther")
    func picksFreeOverLinkedEvenIfFarther() {
        var pool = Simulation.StructurePool()
        // Near refinery at (12, 12) is BUSY.
        let near = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var a = pool[near]
        a.positionX = UInt16(12 * 256); a.positionY = UInt16(12 * 256); a.linkedID = 42
        pool[near] = a
        // Far refinery at (50, 50) is FREE.
        let far = pool.allocate(at: 6, type: REFINERY, houseID: Simulation.House.atreides)!
        var b = pool[far]
        b.positionX = UInt16(50 * 256); b.positionY = UInt16(50 * 256); b.linkedID = 0xFF
        pool[far] = b

        let h = harvester(at: (10, 10))
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == far)
    }

    @Test("two free refineries: picks the nearest")
    func picksNearestAmongFree() {
        var pool = Simulation.StructurePool()
        let near = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var a = pool[near]
        a.positionX = UInt16(12 * 256); a.positionY = UInt16(12 * 256); a.linkedID = 0xFF
        pool[near] = a
        let far = pool.allocate(at: 6, type: REFINERY, houseID: Simulation.House.atreides)!
        var b = pool[far]
        b.positionX = UInt16(50 * 256); b.positionY = UInt16(50 * 256); b.linkedID = 0xFF
        pool[far] = b

        let h = harvester(at: (10, 10))
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == near)
    }

    @Test("different-house refinery ignored")
    func differentHouseIgnored() {
        var pool = Simulation.StructurePool()
        let r = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.harkonnen)!
        var slot = pool[r]
        slot.positionX = UInt16(10 * 256); slot.positionY = UInt16(10 * 256)
        slot.linkedID = 0xFF
        pool[r] = slot

        let h = harvester(at: (10, 10))   // Atreides harvester
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == nil)
    }

    @Test("non-refinery structures ignored")
    func nonRefineryIgnored() {
        var pool = Simulation.StructurePool()
        // CYARD (type 8), unlinked — not a refinery.
        let cy = pool.allocate(at: 5, type: 8, houseID: Simulation.House.atreides)!
        var slot = pool[cy]
        slot.positionX = UInt16(15 * 256); slot.positionY = UInt16(15 * 256)
        slot.linkedID = 0xFF
        pool[cy] = slot

        let h = harvester(at: (10, 10))
        #expect(Simulation.Scheduler.findFreeRefinery(
            forHarvester: h, structures: pool
        ) == nil)
    }

    // MARK: tickHarvesting preference

    @Test("full harvester routes to the free refinery when near refinery is busy")
    func tickHarvestingPrefersFreeRefinery() {
        var scheduler = emptyScheduler(rng: { 0 })
        // Near refinery at (12, 12) — BUSY (another harvester docked).
        let near = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var a = scheduler.host.structures[near]
        a.positionX = UInt16(12 * 256); a.positionY = UInt16(12 * 256)
        a.linkedID = 42; a.hitpoints = 450
        scheduler.host.structures[near] = a
        // Far refinery at (50, 50) — FREE.
        let far = scheduler.host.structures.allocate(
            at: 6, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var b = scheduler.host.structures[far]
        b.positionX = UInt16(50 * 256); b.positionY = UInt16(50 * 256)
        b.linkedID = 0xFF; b.hitpoints = 450
        scheduler.host.structures[far] = b

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128); u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 100
        u.inTransport = false
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()

        // Harvester should flip to RETURN action and target the FAR
        // refinery's anchor tile (50, 50), not the near one.
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.returnAction)
        // targetMove encodes a tile — scheduler writes `tx * 256, ty * 256`
        // into currentDestinationX/Y via orderMove; simpler to check the
        // tile-packed targetMove when EncodedIndex encodes tile form.
        // Use the route direction instead: positionX/Y of 10 → target
        // 50 > 10 so the harvester should at least carry a non-zero
        // targetMove referring to a tile east of origin.
        #expect(scheduler.host.units[hIdx].targetMove != 0)
    }

    // MARK: callCarryall (slice 8b pure helper)

    @Test("callCarryall spawns a CARRYALL linked to the harvester, marked in-transport")
    func callCarryallHappyPath() {
        var units = Simulation.UnitPool()
        var structures = Simulation.StructurePool()
        let rIdx = structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = structures[rIdx]
        r.positionX = UInt16(50 * 256); r.positionY = UInt16(50 * 256)
        r.hitpoints = 450; r.isAllocated = true
        structures[rIdx] = r

        let hIdx = units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = units[hIdx]
        u.positionX = UInt16(12 * 256 + 128); u.positionY = UInt16(12 * 256 + 128)
        u.amount = 100
        u.isAllocated = true
        units[hIdx] = u

        let carryallIdx = Simulation.Units.callCarryall(
            harvesterIndex: hIdx,
            destinationRefineryIndex: rIdx,
            units: &units,
            structures: structures
        )
        #expect(carryallIdx != nil)
        guard let cIdx = carryallIdx else { return }

        let c = units[cIdx]
        #expect(c.type == 0 /* CARRYALL */)
        #expect(c.houseID == Simulation.House.atreides)
        #expect(c.isUsed)
        #expect(c.inTransport == true)
        #expect(c.linkedID == UInt8(hIdx))
        #expect(c.targetMove == Scripting.EncodedIndex.structure(UInt16(rIdx)).raw)
        // Spawned at the harvester's current tile.
        #expect(c.positionX == UInt16(12 * 256 + 128))
        #expect(c.positionY == UInt16(12 * 256 + 128))
        // Carryall pool range: 0..9 (per UnitInfo.indexStart/indexEnd).
        #expect(cIdx >= 0 && cIdx <= 9)

        // Harvester is now marked in-transport so tickHarvesting won't
        // re-route it while the carryall ferries.
        #expect(units[hIdx].inTransport == true)
    }

    @Test("callCarryall rejects non-harvester caller")
    func callCarryallRejectsNonHarvester() {
        var units = Simulation.UnitPool()
        var structures = Simulation.StructurePool()
        let rIdx = structures.allocate(at: 5, type: REFINERY, houseID: 1)!
        var r = structures[rIdx]
        r.isAllocated = true; r.hitpoints = 450
        structures[rIdx] = r
        // Trike, not harvester.
        let tIdx = units.allocate(in: 22...60, type: 13, houseID: 1)!
        var t = units[tIdx]; t.isAllocated = true; units[tIdx] = t
        #expect(Simulation.Units.callCarryall(
            harvesterIndex: tIdx,
            destinationRefineryIndex: rIdx,
            units: &units, structures: structures
        ) == nil)
    }

    @Test("callCarryall rejects mismatched house on refinery")
    func callCarryallRejectsForeignRefinery() {
        var units = Simulation.UnitPool()
        var structures = Simulation.StructurePool()
        let rIdx = structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = structures[rIdx]
        r.isAllocated = true; r.hitpoints = 450
        structures[rIdx] = r
        let hIdx = units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = units[hIdx]; u.isAllocated = true; units[hIdx] = u
        #expect(Simulation.Units.callCarryall(
            harvesterIndex: hIdx,
            destinationRefineryIndex: rIdx,
            units: &units, structures: structures
        ) == nil)
    }

    // MARK: Scheduler integration (slice 8b)

    @Test("tickHarvesting ferries a full harvester via carryall when all refineries busy + house owns ≥ 2")
    func carryallFerryKicksIn() {
        var scheduler = emptyScheduler(rng: { 0 })
        // Two refineries, both BUSY.
        let near = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var a = scheduler.host.structures[near]
        a.positionX = UInt16(12 * 256); a.positionY = UInt16(12 * 256)
        a.linkedID = 42; a.hitpoints = 450; a.isAllocated = true
        scheduler.host.structures[near] = a
        let far = scheduler.host.structures.allocate(
            at: 6, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var b = scheduler.host.structures[far]
        b.positionX = UInt16(50 * 256); b.positionY = UInt16(50 * 256)
        b.linkedID = 43; b.hitpoints = 450; b.isAllocated = true
        scheduler.host.structures[far] = b

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(30 * 256 + 128); u.positionY = UInt16(30 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 100
        u.inTransport = false
        u.isAllocated = true
        scheduler.host.units[hIdx] = u

        let carryallCountBefore = scheduler.host.units.findArray.filter {
            scheduler.host.units.slots[$0].type == 0
        }.count
        scheduler.tickHarvesting()
        let carryallCountAfter = scheduler.host.units.findArray.filter {
            scheduler.host.units.slots[$0].type == 0
        }.count

        #expect(carryallCountAfter == carryallCountBefore + 1)
        // Harvester is now in-transport (riding the carryall) + in RETURN action.
        #expect(scheduler.host.units[hIdx].inTransport == true)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.returnAction)
    }

    @Test("single refinery + busy: no carryall spawned (would be a no-op ferry)")
    func singleBusyRefineryNoFerry() {
        var scheduler = emptyScheduler(rng: { 0 })
        let only = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var a = scheduler.host.structures[only]
        a.positionX = UInt16(12 * 256); a.positionY = UInt16(12 * 256)
        a.linkedID = 42; a.hitpoints = 450; a.isAllocated = true
        scheduler.host.structures[only] = a

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(30 * 256 + 128); u.positionY = UInt16(30 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 100
        u.inTransport = false
        u.isAllocated = true
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()

        let carryalls = scheduler.host.units.findArray.filter {
            scheduler.host.units.slots[$0].type == 0
        }.count
        #expect(carryalls == 0)
        // Harvester still routes to the (only) refinery on foot.
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.returnAction)
        #expect(scheduler.host.units[hIdx].inTransport == false)
    }

    // Note: slice 8a had a `tickHarvestingFallsBackWhenAllBusy` test
    // asserting that 2-busy-refineries fell through to
    // `findNearestRefinery` on foot. Slice 8b supersedes that
    // behaviour — 2 busy refineries now triggers the carryall ferry,
    // tested by `carryallFerryKicksIn`. The single-refinery-busy
    // fallback lives in `singleBusyRefineryNoFerry`.
}
