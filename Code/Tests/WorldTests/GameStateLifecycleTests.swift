import Testing
import DuneIIContracts
@testable import DuneIIWorld

/// Tests for the object/reference lifecycle bookkeeping on `GameState` (`GameState+Lifecycle.swift`):
/// `Unit_RemoveFromTeam`, `Object_Script_Variable4_Set/Clear`, `Structure_SetState`, and the
/// reference-scrubbing `Unit_UntargetMe`. Faithful to OpenDUNE `src/object.c`/`structure.c`/`unit.c`.
@Suite("GameState object lifecycle")
struct GameStateLifecycleTests {
    private func u(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }
    private func st(_ t: StructureType) -> UInt8 { UInt8(t.rawValue) }

    @Test("unitRemoveFromTeam drops membership and returns the free-slot count")
    func unitRemoveFromTeam() {
        var s = GameState()
        s.houses[0].unitCountMax = 100
        let unit = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let team = s.teamAllocate(index: Pool.teamIndexInvalid)!
        s.teams[team].maxMembers = 4
        s.teams[team].members = 2
        s.units[unit].team = UInt8(team + 1)   // team field is 1-based

        #expect(s.unitRemoveFromTeam(unit) == 3)   // maxMembers 4 - members 1 = 3 free
        #expect(s.units[unit].team == 0)
        #expect(s.teams[team].members == 1)
        #expect(s.unitRemoveFromTeam(unit) == 0)   // no team now → no-op
    }

    @Test("Object_Script_Variable4 forms and clears a two-way link")
    func scriptVariable4Link() {
        var s = GameState()
        s.houses[0].unitCountMax = 100
        let a = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let b = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let encA = s.indexEncode(s.units[a].o.index, type: .unit)
        let encB = s.indexEncode(s.units[b].o.index, type: .unit)

        s.objectScriptVariable4Set(.unit(a), encB)
        s.objectScriptVariable4Set(.unit(b), encA)
        #expect(s.units[a].o.script.variables[4] == encB)
        #expect(s.units[b].o.script.variables[4] == encA)

        s.objectScriptVariable4Clear(.unit(a))   // clears both ends
        #expect(s.units[a].o.script.variables[4] == 0)
        #expect(s.units[b].o.script.variables[4] == 0)
    }

    @Test("Variable4 flips an incoming-busy structure's state (refinery)")
    func scriptVariable4StructureState() {
        var s = GameState()
        let r = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.refinery))!  // busyStateIsIncoming
        #expect(s.structures[r].state == .idle)
        s.objectScriptVariable4Set(.structure(r), 0x4001)   // non-zero ⇒ BUSY
        #expect(s.structures[r].state == .busy)
        s.objectScriptVariable4Set(.structure(r), 0)        // zero ⇒ IDLE
        #expect(s.structures[r].state == .idle)

        // With a linked unit, the state is left alone.
        s.structures[r].o.linkedID = 5
        s.objectScriptVariable4Set(.structure(r), 0x4002)
        #expect(s.structures[r].state == .idle)
    }

    @Test("unitUntargetMe scrubs every reference to a unit")
    func unitUntargetMe() {
        var s = GameState()
        s.houses[0].unitCountMax = 100
        let victim = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let other = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let encV = s.indexEncode(s.units[victim].o.index, type: .unit)
        let encO = s.indexEncode(s.units[other].o.index, type: .unit)

        s.units[other].targetMove = encV
        s.units[other].targetAttack = encV
        s.objectScriptVariable4Set(.unit(other), encV)   // two-way var4 link
        s.objectScriptVariable4Set(.unit(victim), encO)

        let turret = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.turret))!
        s.structures[turret].o.script.variables[2] = encV

        let team = s.teamAllocate(index: Pool.teamIndexInvalid)!
        s.teams[team].maxMembers = 4
        s.teams[team].members = 1
        s.teams[team].target = encV
        s.units[victim].team = UInt8(team + 1)

        s.unitUntargetMe(victim)

        #expect(s.units[other].targetMove == 0)
        #expect(s.units[other].targetAttack == 0)
        #expect(s.units[other].o.script.variables[4] == 0)
        #expect(s.units[victim].o.script.variables[4] == 0)
        #expect(s.structures[turret].o.script.variables[2] == 0)
        #expect(s.teams[team].target == 0)
        #expect(s.units[victim].team == 0)
        #expect(s.teams[team].members == 0)
    }
}
