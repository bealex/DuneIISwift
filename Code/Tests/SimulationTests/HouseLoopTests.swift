import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// `GameLoop_House` (`house.c:51`) — the House phase. The core economy runs on `tickHouse` (clamp credits to
/// storage + `House_CalculatePowerAndCredit` + the attack-timer decrements) and `tickPowerMaintenance` (the
/// power-upkeep deduction). Both cursors start at 0 so they fire on the first tick.
@Suite("GameLoop_House economy")
struct HouseLoopTests {
    private func place(_ s: inout GameState, _ type: StructureType, house: UInt8) {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
    }

    @Test("tickHouse clamps over-storage credits and recomputes power/credit")
    func clampAndRecompute() {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        place(&s, .refinery, house: 0)   // 1005 storage, 30 power usage
        place(&s, .windtrap, house: 0)   // 100 power production
        s.houseCalculatePowerAndCredit(0)   // mimic Game_Prepare so the clamp sees real storage
        s.houses[0].credits = 5000          // far above storage
        s.houseTick.powerMaintenance = 1_000_000   // isolate: no upkeep deduction this tick

        var sim = Simulation(state: s)
        sim.tick()   // tick 1 → tickHouse fires
        #expect(sim.state.houses[0].credits == 1005)        // overflow above storage lost
        #expect(sim.state.houses[0].powerProduction == 100) // recomputed
        #expect(sim.state.houses[0].powerUsage == 30)
        #expect(sim.state.houses[0].creditsStorage == 1005)
    }

    @Test("tickPowerMaintenance deducts the power upkeep (powerUsage/32 + 1)")
    func powerMaintenance() {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        s.houses[0].powerUsage = 64        // cost = 64/32 + 1 = 3
        s.houses[0].credits = 100
        s.houseTick.house = 1_000_000      // isolate: no clamp/recompute this tick

        var sim = Simulation(state: s)
        sim.tick()
        #expect(sim.state.houses[0].credits == 97)
    }

    @Test("tickHouse decrements the per-house attack timers (not below zero)")
    func attackTimers() {
        var s = GameState()
        _ = s.houseAllocate(index: 0)
        s.houses[0].timerUnitAttack = 2
        s.houses[0].timerStructureAttack = 1
        s.houses[0].timerSandwormAttack = 0   // already zero → stays zero
        s.houseTick.powerMaintenance = 1_000_000

        var sim = Simulation(state: s)
        sim.tick()
        #expect(sim.state.houses[0].timerUnitAttack == 1)
        #expect(sim.state.houses[0].timerStructureAttack == 0)
        #expect(sim.state.houses[0].timerSandwormAttack == 0)
    }

    @Test("the house economy does not run while paused")
    func pausedFreezesEconomy() {
        var s = GameState()
        _ = s.houseAllocate(index: 0)
        s.houses[0].credits = 5000   // storage stays 0 → an unpaused tick would clamp to 0
        s.paused = true

        var sim = Simulation(state: s)
        sim.tick()   // paused → no game phases
        #expect(sim.state.houses[0].credits == 5000)   // unclamped — the House phase never ran
    }
}
