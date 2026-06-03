import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Decision-trace coverage of the team "brain" recruit/target natives (`script/team.c`): `AddClosestUnit`
/// (recruit the nearest eligible unit), `GetAverageDistance` (centroid + mean distance), `FindBestTarget`
/// (pick a member's best target). See `Documentation/Algorithms/TeamScript.md`.
@Suite("Team brain natives (recruit + target)")
struct TeamScriptFunctionsTests {
    private let fns = TeamScriptFunctions()

    private func newState() -> GameState {
        var s = GameState(); _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100; s.houses[2].unitCountMax = 100
        return s
    }

    private func makeTeam(
        _ s: inout GameState,
        house: UInt8 = 0,
        move: MovementType = .wheeled,
        maxMembers: UInt16 = 3,
        at packed: UInt16
    ) -> Int {
        let slot = s.teamAllocate(index: Pool.teamIndexInvalid)!
        s.teams[slot].houseID = house
        s.teams[slot].movementType = UInt16(move.rawValue)
        s.teams[slot].maxMembers = maxMembers
        s.teams[slot].position = Tile32.unpack(packed)
        return slot
    }

    @discardableResult
    private func addUnit(
        _ s: inout GameState,
        _ type: UnitType,
        house: UInt8 = 0,
        at packed: UInt16,
        byScenario: Bool = true
    ) -> Int {
        let slot = s.unitAllocate(index: 0xFFFF, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(packed)
        if byScenario { s.units[slot].o.flags.insert(.byScenario) }
        return slot
    }

    @Test("addClosestUnit recruits the nearest eligible same-house unit and returns the free slots")
    func recruitsNearest() {
        var s = newState()
        let team = makeTeam(&s, at: Tile32.packXY(x: 10, y: 10))
        let near = addUnit(&s, .trike, at: Tile32.packXY(x: 12, y: 10))
        let far = addUnit(&s, .trike, at: Tile32.packXY(x: 20, y: 10))

        let free = fns.addClosestUnit(slot: team, in: &s)
        #expect(s.units[near].team == UInt8(team) + 1)
        #expect(s.units[far].team == 0)
        #expect(s.teams[team].members == 1)
        #expect(free == 2)
    }

    @Test("addClosestUnit skips saboteurs, the wrong movementType, and non-scenario units")
    func recruitEligibility() {
        var s = newState()
        let team = makeTeam(&s, move: .wheeled, at: Tile32.packXY(x: 10, y: 10))
        addUnit(&s, .saboteur, at: Tile32.packXY(x: 11, y: 10))  // saboteur — skip
        addUnit(&s, .tank, at: Tile32.packXY(x: 11, y: 10))  // tracked, not wheeled — skip
        addUnit(&s, .trike, at: Tile32.packXY(x: 13, y: 10), byScenario: false)  // not byScenario — skip
        let ok = addUnit(&s, .trike, at: Tile32.packXY(x: 15, y: 10))  // the only eligible one

        _ = fns.addClosestUnit(slot: team, in: &s)
        #expect(s.units[ok].team == UInt8(team) + 1)
        #expect(s.teams[team].members == 1)
    }

    @Test("addClosestUnit returns 0 when the team is already full")
    func recruitFull() {
        var s = newState()
        let team = makeTeam(&s, maxMembers: 0, at: Tile32.packXY(x: 10, y: 10))
        addUnit(&s, .trike, at: Tile32.packXY(x: 11, y: 10))
        #expect(fns.addClosestUnit(slot: team, in: &s) == 0)
        #expect(s.teams[team].members == 0)
    }

    @Test("getAverageDistance centres the team on its members and returns their mean distance")
    func averageDistance() {
        var s = newState()
        let team = makeTeam(&s, at: 0)
        let a = addUnit(&s, .trike, at: Tile32.packXY(x: 10, y: 10)); s.units[a].team = UInt8(team) + 1
        let b = addUnit(&s, .trike, at: Tile32.packXY(x: 20, y: 10)); s.units[b].team = UInt8(team) + 1
        s.teams[team].members = 2

        let d = fns.getAverageDistance(slot: team, in: &s)
        #expect(Tile32.packedX(s.teams[team].position.packed) == 15)  // centroid x
        #expect(Tile32.packedY(s.teams[team].position.packed) == 10)  // centroid y
        #expect(d == 5)  // each member ~5 tiles out
    }

    @Test("getAverageDistance returns 0 with no members")
    func averageNoMembers() {
        var s = newState()
        let team = makeTeam(&s, at: Tile32.packXY(x: 10, y: 10))
        #expect(fns.getAverageDistance(slot: team, in: &s) == 0)
    }

    @Test("findBestTarget picks an enemy a team member can see and stores it as the team target")
    func findsTarget() {
        var s = newState()
        let team = makeTeam(&s, house: 0, at: Tile32.packXY(x: 10, y: 10))
        let member = addUnit(&s, .trike, house: 0, at: Tile32.packXY(x: 10, y: 10))
        s.units[member].team = UInt8(team) + 1; s.teams[team].members = 1
        let enemy = addUnit(&s, .trike, house: 2, at: Tile32.packXY(x: 13, y: 10))
        s.units[enemy].o.seenByHouses |= UInt8(1 << 0)  // visible to house 0

        let got = fns.findBestTarget(slot: team, targets: TargetFinder(), in: &s)
        #expect(got != 0)
        #expect(s.teams[team].target == got)
    }

    @Test("findBestTarget returns 0 with no members")
    func noTargetNoMembers() {
        var s = newState()
        let team = makeTeam(&s, at: Tile32.packXY(x: 10, y: 10))
        #expect(fns.findBestTarget(slot: team, targets: TargetFinder(), in: &s) == 0)
    }

    // MARK: - Order-issuing natives (need the unit-action layer)

    private let actions = UnitActions()
    private let unitFuncs = UnitScriptFunctions(unitPrimitives: DefaultUnitPrimitives())
    /// A synthetic unit script: every unit type's entry points at a trivial program (we only assert the
    /// action/target changes, not the loaded member scripts).
    private let unitScript = ScriptInfo(program: [ 0 ], offsets: [UInt16](repeating: 0, count: 64))

    @Test("moveOrGuardMembers: a strayed member is sent to Move, an in-place one Guards")
    func moveOrGuard() {
        var s = newState()
        let team = makeTeam(&s, at: Tile32.packXY(x: 10, y: 10))
        let strayed = addUnit(&s, .trike, at: Tile32.packXY(x: 20, y: 10)); s.units[strayed].team = UInt8(team) + 1
        let inPlace = addUnit(&s, .trike, at: Tile32.packXY(x: 11, y: 10)); s.units[inPlace].team = UInt8(team) + 1
        s.teams[team].members = 2

        let moved = fns.moveOrGuardMembers(
            slot: team,
            distance: 2,
            unitScript: unitScript,
            actions: actions,
            unitFuncs: unitFuncs,
            in: &s
        )
        #expect(moved == 1)
        #expect(s.units[strayed].actionID == UInt8(ActionType.move.rawValue))
        #expect(s.units[strayed].targetMove != 0)  // a destination was set
        #expect(s.units[inPlace].actionID == UInt8(ActionType.guard_.rawValue))
    }

    @Test("issueAttackOrders: each member is set to Attack the team target with a destination")
    func issueAttack() {
        var s = newState()
        let team = makeTeam(&s, house: 0, at: Tile32.packXY(x: 10, y: 10))
        let member = addUnit(&s, .trike, house: 0, at: Tile32.packXY(x: 10, y: 10))
        s.units[member].team = UInt8(team) + 1; s.teams[team].members = 1
        let enemy = addUnit(&s, .tank, house: 2, at: Tile32.packXY(x: 20, y: 10))
        let target = s.indexEncode(s.units[enemy].o.index, type: .unit)
        s.teams[team].target = target

        let r = fns.issueAttackOrders(
            slot: team,
            unitScript: unitScript,
            actions: actions,
            unitFuncs: unitFuncs,
            in: &s
        )
        #expect(r == 0)
        #expect(s.units[member].actionID == UInt8(ActionType.attack.rawValue))
        #expect(s.units[member].targetAttack == target)
        #expect(s.units[member].targetMove != 0)  // a firing position was set
    }

    @Test("issueAttackOrders is a no-op without a target")
    func issueAttackNoTarget() {
        var s = newState()
        let team = makeTeam(&s, house: 0, at: Tile32.packXY(x: 10, y: 10))
        let member = addUnit(&s, .trike, house: 0, at: Tile32.packXY(x: 10, y: 10))
        s.units[member].team = UInt8(team) + 1; s.teams[team].members = 1

        #expect(
            fns.issueAttackOrders(
                slot: team,
                unitScript: unitScript,
                actions: actions,
                unitFuncs: unitFuncs,
                in: &s
            ) == 0
        )
        #expect(s.units[member].targetAttack == 0)  // untouched
    }

    @Test("load switches the team's action + reloads the script engine; same action is a no-op")
    func loadSwitches() {
        var s = newState()
        let team = makeTeam(&s, at: Tile32.packXY(x: 10, y: 10))
        let teamScript = ScriptInfo(program: [UInt16](repeating: 0, count: 40), offsets: [ 10, 20, 30 ])
        let interp = DefaultScriptInterpreter()
        var engine = s.teams[team].script

        _ = fns.load(slot: team, type: 1, interpreter: interp, scriptInfo: teamScript, engine: &engine, in: &s)
        #expect(s.teams[team].action == 1)
        #expect(engine.scriptPC == 20)  // offsets[1]

        engine.scriptPC = 99
        _ = fns.load(slot: team, type: 1, interpreter: interp, scriptInfo: teamScript, engine: &engine, in: &s)
        #expect(engine.scriptPC == 99)  // already action 1 → no reload
    }

    @Test("load2 reloads the team's starting action script")
    func load2Reloads() {
        var s = newState()
        let team = makeTeam(&s, at: Tile32.packXY(x: 10, y: 10))
        s.teams[team].actionStart = 2
        let teamScript = ScriptInfo(program: [UInt16](repeating: 0, count: 40), offsets: [ 10, 20, 30 ])
        var engine = s.teams[team].script

        _ = fns.load2(
            slot: team,
            interpreter: DefaultScriptInterpreter(),
            scriptInfo: teamScript,
            engine: &engine,
            in: &s
        )
        #expect(s.teams[team].action == 2)
        #expect(engine.scriptPC == 30)  // offsets[2]
    }
}
