import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// `GameLoop_Team` + the team script subsystem (`team.c:22`, `script/team.c`). Covers the getter natives
/// (decision-trace), and — bridging the committed `TEAM.EMC` — the loop's behaviour: it fires on the random
/// cursor and re-arms, runs an `isAIActive` house's team script, skips a non-AI house's team, and decrements
/// a suspended team's `delay`. See `Documentation/Algorithms/TeamScript.md`.
@Suite("Team scripts + GameLoop_Team")
struct TeamLoopTests {
    private func emc(_ relative: String) -> ScriptInfo? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/SimulationTests → repo root
        guard
            let data = try? Data(contentsOf: repo.appendingPathComponent(relative)),
            let program = try? Emc.Program(data)
        else { return nil }
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

        sim.tick()  // timerGame 1; cursor starts 0 → fires

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

        #expect(sim.state.teamLoopTick >= 6 && sim.state.teamLoopTick <= 13)  // loop still fired
        #expect(sim.state.teams[slot].script == loaded)  // but the team didn't run
    }

    @Test("a suspended team has its script delay decremented, not run")
    func loopDecrementsDelay() throws {
        guard var (sim, slot) = setup() else { return }
        sim.state.teams[slot].script.delay = 3
        let loadedPC = sim.state.teams[slot].script.scriptPC

        sim.tick()

        #expect(sim.state.teams[slot].script.delay == 2)  // decremented
        #expect(sim.state.teams[slot].script.scriptPC == loadedPC)  // no opcode ran
    }

    @Test("end-to-end: an AI team recruits members, acquires a target, and orders an attack")
    func endToEndTeamAI() throws {
        guard
            let teamEMC = emc("Resources/Scripts/TEAM/TEAM.emc"),
            let unitEMC = emc("Resources/Scripts/UNIT/UNIT.emc")
        else { return }
        var s = GameState(random256Seed: 0xBEEF)
        s.playerHouseID = 1  // house 0 is the AI; house 1 is the (human) enemy
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100; s.houses[0].flags.insert(.isAIActive)
        _ = s.houseAllocate(index: 1); s.houses[1].unitCountMax = 100

        func tank(house: UInt8, at packed: UInt16, scenario: Bool) -> Int {
            let u = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: house)!
            s.units[u].o.position = Tile32.unpack(packed)
            s.units[u].o.hitpoints = UnitInfo[.tank].o.hitpoints
            s.units[u].o.flags.insert(.allocated)  // targetable (targetUnitPriority requires it)
            if scenario { s.units[u].o.flags.insert(.byScenario) }
            s.unitUpdateMap(1, u)
            return u
        }
        // Three recruitable AI tanks, clustered, plus a (seen) enemy tank to target. (Tanks allocate into
        // their type band, not slots 0…3, so capture the real slots.)
        let members = [
            tank(house: 0, at: Tile32.packXY(x: 20, y: 20), scenario: true),
            tank(house: 0, at: Tile32.packXY(x: 21, y: 20), scenario: true),
            tank(house: 0, at: Tile32.packXY(x: 20, y: 21), scenario: true),
        ]
        let enemy = tank(house: 1, at: Tile32.packXY(x: 28, y: 20), scenario: false)
        s.units[enemy].o.seenByHouses = 0xFF  // visible to the AI → findable as a target

        // The team running the `normal` brain (recruit → average-distance → target → attack orders → loop).
        let team = s.teamCreate(
            houseID: 0,
            teamActionType: UInt8(TeamActionType.normal.rawValue),
            movementType: UInt8(MovementType.tracked.rawValue),
            minMembers: 2,
            maxMembers: 4,
            scriptPC: teamEMC.offsets[Int(TeamActionType.normal.rawValue)]
        )!
        s.viewportPosition = Tile32.packXY(x: 12, y: 12)

        // Track the full chain across the run — the AI evolves (recruits attack, fight, may die), so the
        // recruit → target → order steps are observed as they happen rather than only in the end-state.
        var everRecruited = false, everTargeted = false, everOrdered = false
        var sim = Simulation(state: s, scriptInfo: unitEMC, teamScriptInfo: teamEMC)
        for _ in 0 ..< 2500 {
            sim.tick()
            if members.contains(where: { sim.state.units[$0].team == UInt8(team + 1) }) { everRecruited = true }
            if sim.state.teams[team].target != 0 { everTargeted = true }
            if members.contains(where: {
                sim.state.units[$0].o.flags.contains(.allocated)
                    && sim.state.units[$0].targetAttack != 0
            }) {
                everOrdered = true
            }
        }

        // The team brain ran end-to-end through the live loop: recruit → acquire a target → order an attack.
        #expect(everRecruited)  // Team_AddClosestUnit pulled a real unit into the team
        #expect(everTargeted)  // Team_FindBestTarget acquired the seen enemy
        #expect(everOrdered)  // Team_Unknown0788 set a member's attack target
    }

    @Test("the team-loop cursor re-arms (one Random256 draw) every fire even with no team script bridged")
    func loopCursorAdvancesWithoutScript() {
        var s = GameState(random256Seed: 0x1234)
        _ = s.houseAllocate(index: 0)
        var sim = Simulation(state: s)  // no teamScriptInfo, no units/structures
        var probe = sim.state.random256
        sim.tick()  // tick 1 → the cursor (0) fires: draws one Random256, re-arms into 6…13
        // OpenDUNE re-arms s_tickTeamGameLoop unconditionally; dropping this draw shifted the shared
        // Random256 stream off the oracle's (the guard/attack-rocket golden bug).
        #expect(sim.state.teamLoopTick >= 6 && sim.state.teamLoopTick <= 13)
        _ = probe.next()  // exactly one draw (the cursor re-arm)…
        #expect(sim.state.random256.next() == probe.next())  // …so the live RNG is one step past the copy
    }
}
