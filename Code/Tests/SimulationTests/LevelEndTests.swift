import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// `GameLoop_IsLevelFinished` / `GameLoop_IsLevelWon` — the mission win/lose evaluation: a level ends when a
/// `WinFlags` condition is met (after a 7200-tick minimum) and `LoseFlags` decides win vs lose. See
/// `Simulation+LevelEnd.swift`.
@Suite("Win / lose conditions")
struct LevelEndTests {
    private func base(winFlags: UInt16, loseFlags: UInt16) -> Simulation {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 1)
        s.scenario.winFlags = winFlags
        s.scenario.loseFlags = loseFlags
        s.tickScenarioStart = 0
        return Simulation(state: s)
    }

    @discardableResult
    private func addStructure(_ s: inout GameState, house: UInt8) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[slot].o.houseID = house
        return slot
    }

    @Test("destroying the last enemy structure wins (WinFlags 1 / LoseFlags 1)")
    func winByDestroyingEnemy() {
        var sim = base(winFlags: 1, loseFlags: 1)
        addStructure(&sim.state, house: 0)                  // the player's base
        let enemy = addStructure(&sim.state, house: 1)      // the enemy's base

        sim.state.timerGame = 5000                          // < 7200 ⇒ too early to decide
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .playing)

        sim.state.timerGame = 8000                          // past the minimum, but the enemy still stands
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .playing)

        sim.state.structureFree(enemy)                       // the enemy's last structure falls
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .won)
    }

    @Test("losing the whole base loses (WinFlags 2 / LoseFlags 1)")
    func loseByLosingBase() {
        var sim = base(winFlags: 2, loseFlags: 1)           // end when no friendly structures; win iff no enemy
        let friendly = addStructure(&sim.state, house: 0)
        addStructure(&sim.state, house: 1)
        sim.state.timerGame = 8000

        sim.state.structureFree(friendly)                     // the player's base is wiped out
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .lost)              // finished, but the enemy survives ⇒ lost
    }

    @Test("reaching the spice quota wins (WinFlags 4 / LoseFlags 4)")
    func winByQuota() {
        var sim = base(winFlags: 4, loseFlags: 4)
        sim.state.houses[0].creditsQuota = 1000
        sim.state.houses[0].credits = 500
        sim.state.timerGame = 8000
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .playing)

        sim.state.houses[0].credits = 1500
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .won)
    }

    @Test("a level never ends before 7200 ticks even with the condition met")
    func minimumDuration() {
        var sim = base(winFlags: 1, loseFlags: 1)
        addStructure(&sim.state, house: 0)                  // no enemy structures at all
        sim.state.timerGame = 7199
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .playing)
        sim.state.timerGame = 7200
        sim.evaluateLevelEnd()
        #expect(sim.state.gameEndState == .won)
    }
}
