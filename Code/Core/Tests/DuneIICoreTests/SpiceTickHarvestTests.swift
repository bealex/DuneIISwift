import Foundation
import Testing
@testable import DuneIICore

@Suite("Scheduler.tickHarvesting — end-to-end harvest + refine")
struct SpiceTickHarvestTests {

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
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: rng
        )
    }

    @Test("HARVEST-action harvester on a thick tile gains amount through tickHarvesting")
    func harvesterPicksUpSpice() {
        var scheduler = emptyScheduler(rng: { 1 })  // jitter=1, gate=1 → no drain
        // Seed a thick spice tile at (10, 10).
        var map = scheduler.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))  // bare → thin
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))  // thin → thick
        scheduler.host.spiceMap = map
        // Allocate a harvester in HARVEST action on that tile.
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        u.inTransport = false
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()
        #expect(scheduler.host.units[hIdx].amount == 1)
        #expect(scheduler.host.units[hIdx].inTransport == true)
        // Tile didn't drain this call (gate=1).
        #expect(scheduler.host.spiceMap![10, 10] == .thick)
    }

    @Test("Docked harvester at refinery accrues credits through tickHarvesting")
    func refineryCreditsDockedHarvester() {
        var scheduler = emptyScheduler(rng: { 0 })
        _ = scheduler.host.houses.allocate(at: Int(Simulation.House.atreides))
        let rIdx = scheduler.host.structures.allocate(
            at: 5, type: REFINERY, houseID: Simulation.House.atreides
        )!
        var r = scheduler.host.structures[rIdx]
        r.hitpoints = 450
        r.state = Simulation.StructureState.idle.rawValue
        scheduler.host.structures[rIdx] = r
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.amount = 30
        scheduler.host.units[hIdx] = u
        _ = Simulation.Structures.dockHarvester(
            refineryIndex: rIdx, harvesterIndex: hIdx,
            structures: &scheduler.host.structures, units: &scheduler.host.units
        )

        let creditsBefore = scheduler.host.houses[Int(Simulation.House.atreides)].credits
        scheduler.tickHarvesting()
        let creditsAfter = scheduler.host.houses[Int(Simulation.House.atreides)].credits
        #expect(creditsAfter == creditsBefore + 21)  // 7 × 3
        #expect(scheduler.host.units[hIdx].amount == 27)
    }

    @Test("Active MOVE-action harvester (with target) isn't harvested")
    func nonHarvestActionSkipped() {
        var scheduler = emptyScheduler(rng: { 1 })
        var map = scheduler.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        scheduler.host.spiceMap = map
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.move  // not harvest
        // `targetMove` != 0 so `idleState` is false — the harvest-pin
        // (which now catches idle non-HARVEST harvesters so user-
        // ordered harvests don't strand in STOP) skips this unit.
        // A MOVE action with no target is a synthetic edge that
        // doesn't appear in live gameplay.
        u.targetMove = 0x4001
        scheduler.host.units[hIdx] = u
        scheduler.tickHarvesting()
        #expect(scheduler.host.units[hIdx].amount == 0)
        #expect(scheduler.host.units[hIdx].actionID == Simulation.ActionID.move)
    }

    @Test("tick() fires harvest every harvestCadenceTicks, not every tick")
    func tickCadence() {
        var scheduler = emptyScheduler(rng: { 1 })
        var map = scheduler.host.spiceMap!
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        scheduler.host.spiceMap = map
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        scheduler.host.units[hIdx] = u

        // cadence = 3: ticks 1,2 produce nothing; tick 3 fires.
        scheduler.tick()
        #expect(scheduler.host.units[hIdx].amount == 0)
        scheduler.tick()
        #expect(scheduler.host.units[hIdx].amount == 0)
        scheduler.tick()
        #expect(scheduler.host.units[hIdx].amount == 1)
    }

    @Test("tick() without spiceMap + rng is a no-op for harvesting")
    func disabledWhenConfigMissing() {
        // No spiceMap on host, no rng.
        let host = Scripting.Host(playerHouseID: Simulation.House.atreides)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm
        )
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.actionID = Simulation.ActionID.harvest
        scheduler.host.units[hIdx] = u
        for _ in 0..<10 { scheduler.tick() }
        #expect(scheduler.host.units[hIdx].amount == 0)
    }
}
