import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld
@testable import DuneIISimulation

/// `GameLoop_Team` + the team script subsystem (`team.c:22`, `script/team.c`). Covers the getter natives
/// (decision-trace), and — bridging the committed `TEAM.EMC` — the loop's behaviour: it fires on the random
/// cursor and re-arms, runs an `isAIActive` house's team script, skips a non-AI house's team, and decrements
/// a suspended team's `delay`. See `Documentation/Algorithms/TeamScript.md`.
@Suite("Team scripts + GameLoop_Team")
struct TeamLoopTests {
    private func emc(_ relative: String) -> ScriptInfo? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/SimulationTests → repo root
        guard let data = try? Data(contentsOf: repo.appendingPathComponent(relative)),
              let program = try? Emc.Program(data) else { return nil }
        return ScriptInfo(program)
    }

    // MARK: - Getter natives (decision-trace)

    @Test("the team getter natives read the running team's fields")
    func getters() {
        var s = GameState()
        let slot = s.teamAllocate(index: Pool.teamIndexInvalid)!
        s.teams[slot].members = 3
        s.teams[slot].minMembers = 2
        s.teams[slot].target = 0x1234

        let fns = TeamScriptFunctions()
        #expect(fns.getMembers(slot: slot, in: s) == 3)
        #expect(fns.getVariable6(slot: slot, in: s) == 2)
        #expect(fns.getTarget(slot: slot, in: s) == 0x1234)
    }

    // MARK: - GameLoop_Team

    /// A `Simulation` with `TEAM.EMC` bridged, an `isAIActive` house 0, and one team running its `normal`
    /// script. Returns the sim + the team slot, or nil if the EMC is absent (short-circuit).
    private func setup(aiActive: Bool = true) -> (Simulation, Int)? {
        guard let teamEMC = emc("Resources/Scripts/TEAM/TEAM.emc") else { return nil }
        var s = GameState(random256Seed: 0x1234)
        _ = s.houseAllocate(index: 0)
        if aiActive { s.houses[0].flags.insert(.isAIActive) }
        let slot = s.teamAllocate(index: Pool.teamIndexInvalid)!
        s.teams[slot].houseID = 0
        s.teams[slot].action = UInt16(TeamActionType.normal.rawValue)

        var sim = Simulation(state: s, teamScriptInfo: teamEMC)
        var engine = sim.state.teams[slot].script
        sim.teamScript!.interpreter.load(&engine, info: teamEMC, typeID: Int(TeamActionType.normal.rawValue))
        sim.state.teams[slot].script = engine
        return (sim, slot)
    }

    @Test("the loop fires on tick 1, re-arms the cursor to +5…12, and advances an AI team's script")
    func loopRunsAITeam() throws {
        guard var (sim, slot) = setup() else { return }
        let loadedPC = sim.state.teams[slot].script.scriptPC

        sim.tick()   // timerGame 1; cursor starts 0 → fires

        // Re-armed into the 5…12-tick window past timerGame (1).
        #expect(sim.state.teamLoopTick >= 6 && sim.state.teamLoopTick <= 13)
        // The team's engine was touched (an opcode ran, or it clean-halted on a brain native).
        let after = sim.state.teams[slot].script
        #expect(after.scriptPC != loadedPC || after.delay != 0)
    }

    @Test("a non-AI house's team is skipped even though the loop fires")
    func loopSkipsNonAITeam() throws {
        guard var (sim, slot) = setup(aiActive: false) else { return }
        let loaded = sim.state.teams[slot].script

        sim.tick()

        #expect(sim.state.teamLoopTick >= 6 && sim.state.teamLoopTick <= 13)   // loop still fired
        #expect(sim.state.teams[slot].script == loaded)                        // but the team didn't run
    }

    @Test("a suspended team has its script delay decremented, not run")
    func loopDecrementsDelay() throws {
        guard var (sim, slot) = setup() else { return }
        sim.state.teams[slot].script.delay = 3
        let loadedPC = sim.state.teams[slot].script.scriptPC

        sim.tick()

        #expect(sim.state.teams[slot].script.delay == 2)               // decremented
        #expect(sim.state.teams[slot].script.scriptPC == loadedPC)     // no opcode ran
    }

    @Test("with no team script bridged, the team phase is inert (no RNG draw)")
    func loopInertWithoutScript() {
        var s = GameState(random256Seed: 0x1234)
        _ = s.houseAllocate(index: 0)
        var sim = Simulation(state: s)   // no teamScriptInfo
        var rngBefore = sim.state.random256
        sim.tick()
        var rngAfter = sim.state.random256
        #expect(sim.state.teamLoopTick == 0)               // never armed
        #expect(rngBefore.next() == rngAfter.next())       // RNG at the same position → team phase drew nothing
    }
}
