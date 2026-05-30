import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

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

    private func makeTeam(_ s: inout GameState, house: UInt8 = 0, move: MovementType = .wheeled,
                          maxMembers: UInt16 = 3, at packed: UInt16) -> Int {
        let slot = s.teamAllocate(index: Pool.teamIndexInvalid)!
        s.teams[slot].houseID = house
        s.teams[slot].movementType = UInt16(move.rawValue)
        s.teams[slot].maxMembers = maxMembers
        s.teams[slot].position = Tile32.unpack(packed)
        return slot
    }

    @discardableResult
    private func addUnit(_ s: inout GameState, _ type: UnitType, house: UInt8 = 0, at packed: UInt16,
                         byScenario: Bool = true) -> Int {
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
        addUnit(&s, .saboteur, at: Tile32.packXY(x: 11, y: 10))                  // saboteur — skip
        addUnit(&s, .tank, at: Tile32.packXY(x: 11, y: 10))                      // tracked, not wheeled — skip
        addUnit(&s, .trike, at: Tile32.packXY(x: 13, y: 10), byScenario: false)  // not byScenario — skip
        let ok = addUnit(&s, .trike, at: Tile32.packXY(x: 15, y: 10))            // the only eligible one

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
        #expect(Tile32.packedX(s.teams[team].position.packed) == 15)   // centroid x
        #expect(Tile32.packedY(s.teams[team].position.packed) == 10)   // centroid y
        #expect(d == 5)                                                // each member ~5 tiles out
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
        s.units[enemy].o.seenByHouses |= UInt8(1 << 0)   // visible to house 0

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
}
