import DuneIIContracts
import DuneIIWorld

/// Win/lose evaluation — a port of `GameLoop_IsLevelFinished` + `GameLoop_IsLevelWon` (`src/opendune.c:120`).
/// The level ends when a `WinFlags` condition is met (after a 7200-tick minimum); whether that's a **win**
/// is then decided by `LoseFlags`. Setting `gameEndState` only flags the outcome — it doesn't halt the loop,
/// so a host/UI reads it. The 0x8 timeout flag is unused in 1.07 (`s_tickGameTimeout` is never set).
public extension Simulation {
    /// Evaluate the level-end conditions and latch `state.gameEndState`. Cheap + idempotent: a no-op once the
    /// game has ended, and before the 7200-tick minimum.
    mutating func evaluateLevelEnd() {
        guard !state.disableLevelEnd else { return }   // debug/UI: play indefinitely (no win/lose latch)
        guard state.gameEndState == .playing else { return }
        if state.timerGame &- state.tickScenarioStart < 7200 { return }
        if levelIsFinished() {
            state.gameEndState = levelIsWon() ? .won : .lost
        }
    }

    /// `GameLoop_IsLevelFinished`: has a `WinFlags` end condition been met?
    func levelIsFinished() -> Bool {
        var finished = false
        let win = state.scenario.winFlags
        if win & 0x3 != 0 {
            let (enemy, friendly) = levelStructureCounts()
            if win & 0x1 != 0 && enemy == 0 { finished = true }
            if win & 0x2 != 0 && friendly == 0 { finished = true }
        }
        if win & 0x4 != 0 && playerReachedQuota() { finished = true }
        return finished
    }

    /// `GameLoop_IsLevelWon`: once finished, did the human win (per `LoseFlags`)?
    func levelIsWon() -> Bool {
        var won = false
        let lose = state.scenario.loseFlags
        if lose & 0x3 != 0 {
            let (enemy, friendly) = levelStructureCounts()
            won = true
            if lose & 0x1 != 0 { won = won && enemy == 0 }
            if lose & 0x2 != 0 { won = won && friendly != 0 }
        }
        if !won && lose & 0x4 != 0 { won = playerReachedQuota() }
        return won
    }

    /// Count of (enemy, friendly) structures, excluding slabs/walls/turrets (`GameLoop_IsLevel*`).
    private func levelStructureCounts() -> (enemy: Int, friendly: Int) {
        var enemy = 0, friendly = 0
        var find = PoolFind()
        while let s = state.structureFind(&find) {
            switch StructureType(rawValue: Int(state.structures[s].o.type)) {
                case .slab1x1, .slab2x2, .wall, .turret, .rocketTurret: continue
                default: break
            }
            if state.structures[s].o.houseID == state.playerHouseID { friendly += 1 } else { enemy += 1 }
        }
        return (enemy, friendly)
    }

    private func playerReachedQuota() -> Bool {
        let h = Int(state.playerHouseID)
        guard h < state.houses.count else { return false }
        let quota = state.houses[h].creditsQuota
        return quota != 0 && state.houses[h].credits >= quota
    }
}
