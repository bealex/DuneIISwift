import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Campaign degrade — the `GameLoop_Structure` degrade body (`structure.c:121`): on later campaigns
/// (`campaignID > 1`), a `degrades` structure above half its base hitpoints loses its house's
/// `degradingAmount` each degrade tick (~every 10800 ticks), down to (but not below) half.
@Suite("Campaign degrade")
struct DegradeTests {
    private func sim(campaign: UInt8, hitpoints: UInt16) -> (Simulation, Int) {
        var s = GameState(); s.playerHouseID = 0; s.campaignID = campaign
        _ = s.houseAllocate(index: 0)
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[slot].o.houseID = 0  // Harkonnen (HouseID 0) — degradingAmount 3
        s.structures[slot].o.hitpoints = hitpoints
        s.structures[slot].hitpointsMax = StructureInfo[.windtrap].o.hitpoints
        s.structures[slot].o.flags.insert(.degrades)
        // Fire only the degrade cursor this tick (structure/script cursors parked in the future).
        s.timerGame = 20000
        s.structureTick.degrade = 0
        s.structureTick.structure = 30000
        s.structureTick.script = 30000
        return (Simulation(state: s), slot)
    }

    private var base: UInt16 { StructureInfo[.windtrap].o.hitpoints }

    @Test("a full-health degrading structure loses degradingAmount on campaign > 1")
    func degradesAboveHalf() {
        var (s, slot) = sim(campaign: 2, hitpoints: StructureInfo[.windtrap].o.hitpoints)
        s.gameLoopStructure()
        #expect(s.state.structures[slot].o.hitpoints == base - 3)  // Harkonnen degradingAmount = 3
    }

    @Test("degrade stops at half hitpoints")
    func stopsAtHalf() {
        var (s, slot) = sim(campaign: 2, hitpoints: StructureInfo[.windtrap].o.hitpoints / 2)
        s.gameLoopStructure()
        #expect(s.state.structures[slot].o.hitpoints == base / 2)  // not > half ⇒ untouched
    }

    @Test("no degrade on campaign 1")
    func noDegradeCampaign1() {
        var (s, slot) = sim(campaign: 1, hitpoints: StructureInfo[.windtrap].o.hitpoints)
        s.gameLoopStructure()
        #expect(s.state.structures[slot].o.hitpoints == base)
    }

    @Test("a non-degrading structure is untouched")
    func nonDegradingUntouched() {
        var (s, slot) = sim(campaign: 2, hitpoints: StructureInfo[.windtrap].o.hitpoints)
        s.state.structures[slot].o.flags.remove(.degrades)
        s.gameLoopStructure()
        #expect(s.state.structures[slot].o.hitpoints == base)
    }
}
