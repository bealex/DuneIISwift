import Foundation
import Testing
@testable import DuneIICore

@Suite("Harvester AI loop — seek refinery when full, dock on arrival, auto-undock on empty")
struct SpiceAILoopTests {

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

    @Test("Full harvester in HARVEST → orderMove issued + actionID flips to RETURN")
    func seekRefineryWhenFull() {
        var scheduler = emptyScheduler(rng: { 1 })
        // Refinery at (30,30) — 3×2 footprint anchored there.
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        scheduler.host.structures[rIdx] = r
        // Full harvester elsewhere in HARVEST.
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.harvest
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()
        let after = scheduler.host.units[hIdx]
        #expect(after.actionID == Simulation.ActionID.returnAction)
        let expected = Scripting.EncodedIndex.tile(
            packed: UInt16(30 * 64 + 30)
        ).raw
        #expect(after.targetMove == expected)
    }

    @Test("RETURN harvester on refinery footprint → dockHarvester fires; state flips to HARVEST")
    func dockOnArrival() {
        var scheduler = emptyScheduler(rng: { 1 })
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        // Stand the harvester on the refinery's anchor tile.
        u.positionX = UInt16(30 * 256 + 128)
        u.positionY = UInt16(30 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.returnAction
        u.inTransport = false
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()
        #expect(scheduler.host.structures[rIdx].linkedID == UInt8(hIdx))
        #expect(scheduler.host.units[hIdx].inTransport == true)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.harvest)
    }

    @Test("Docked harvester drains to zero → auto-undock; actionID stays HARVEST; refinery idle")
    func autoUndockOnEmpty() {
        var scheduler = emptyScheduler(rng: { 0 })
        _ = scheduler.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.amount = 2  // one refine tick of 3 will overshoot; drains to 0
        scheduler.host.units[hIdx] = u
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &scheduler.host.structures, units: &scheduler.host.units
        )
        #expect(scheduler.host.structures[rIdx].linkedID == UInt8(hIdx))

        // One harvesting pass drains everything + auto-undocks.
        scheduler.tickHarvesting()
        #expect(scheduler.host.units[hIdx].amount == 0)
        #expect(scheduler.host.structures[rIdx].linkedID == 0xFF)
        #expect(scheduler.host.structures[rIdx].state == Simulation.StructureState.idle.rawValue)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.harvest)
    }

    @Test("Full cycle: seek → move-simulated → dock → drain → undock (multi-pass)")
    func fullCycle() {
        var scheduler = emptyScheduler(rng: { 0 })
        _ = scheduler.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.positionX = UInt16(30 * 256)
        r.positionY = UInt16(30 * 256)
        r.hitpoints = 450
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.amount = 100
        u.actionID = Simulation.ActionID.harvest
        scheduler.host.units[hIdx] = u

        // Pass 1: seek — flips to RETURN with move target.
        scheduler.tickHarvesting()
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.returnAction)

        // Simulate movement: teleport harvester onto refinery.
        u = scheduler.host.units[hIdx]
        u.positionX = UInt16(30 * 256 + 128)
        u.positionY = UInt16(30 * 256 + 128)
        scheduler.host.units[hIdx] = u

        // Pass 2: arrival — dock, flip action to HARVEST.
        scheduler.tickHarvesting()
        #expect(scheduler.host.structures[rIdx].linkedID == UInt8(hIdx))
        #expect(scheduler.host.units[hIdx].inTransport == true)

        // Passes 3..N: refine drains amount; eventually auto-undock.
        // With rng=0, refine hits full 3/tick; 100/3 = 34 ticks.
        var safety = 0
        while scheduler.host.structures[rIdx].linkedID != 0xFF, safety < 50 {
            scheduler.tickHarvesting()
            safety += 1
        }
        #expect(scheduler.host.units[hIdx].amount == 0)
        #expect(scheduler.host.structures[rIdx].linkedID == 0xFF)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.harvest)
        // Credits: 100 spice × 7 = 700.
        #expect(scheduler.host.houses[Int(Simulation.House.atreides)].credits >= 700)
    }

    @Test("findNearestRefinery picks the closest, skips enemy refineries")
    func nearestRefineryPreferred() {
        var pool = Simulation.StructurePool()
        let near = pool.allocate(at: 5, type: REFINERY, houseID: Simulation.House.atreides)!
        var n = pool[near]
        n.positionX = UInt16(15 * 256)
        n.positionY = UInt16(15 * 256)
        pool[near] = n
        let far = pool.allocate(at: 6, type: REFINERY, houseID: Simulation.House.atreides)!
        var f = pool[far]
        f.positionX = UInt16(60 * 256)
        f.positionY = UInt16(60 * 256)
        pool[far] = f
        let enemy = pool.allocate(at: 7, type: REFINERY, houseID: Simulation.House.harkonnen)!
        var e = pool[enemy]
        e.positionX = UInt16(11 * 256)
        e.positionY = UInt16(11 * 256)
        pool[enemy] = e

        var harvester = Simulation.UnitSlot()
        harvester.positionX = UInt16(10 * 256 + 128)
        harvester.positionY = UInt16(10 * 256 + 128)
        harvester.houseID = Simulation.House.atreides
        let picked = Simulation.Scheduler.findNearestRefinery(
            forHarvester: harvester, structures: pool
        )
        #expect(picked == near)
    }
}
