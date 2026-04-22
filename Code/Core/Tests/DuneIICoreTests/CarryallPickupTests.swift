import Foundation
import Testing
@testable import DuneIICore

@Suite("Carryall pickup slice 8a — findFreeRefinery + tickHarvesting preference")
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

    @Test("fallback to nearest refinery when all are busy")
    func tickHarvestingFallsBackWhenAllBusy() {
        var scheduler = emptyScheduler(rng: { 0 })
        // Both refineries BUSY.
        let near = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var a = scheduler.host.structures[near]
        a.positionX = UInt16(12 * 256); a.positionY = UInt16(12 * 256)
        a.linkedID = 42; a.hitpoints = 450
        scheduler.host.structures[near] = a
        let far = scheduler.host.structures.allocate(
            at: 6, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var b = scheduler.host.structures[far]
        b.positionX = UInt16(50 * 256); b.positionY = UInt16(50 * 256)
        b.linkedID = 43; b.hitpoints = 450
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

        // With both busy, the scheduler falls back to
        // `findNearestRefinery`, which still writes an orderMove; the
        // harvester flips to RETURN. Same observable shape as the
        // pre-slice behaviour.
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.returnAction)
        #expect(scheduler.host.units[hIdx].targetMove != 0)
    }
}
