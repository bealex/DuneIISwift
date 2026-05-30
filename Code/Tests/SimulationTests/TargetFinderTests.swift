import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// Decision-trace coverage for `Unit_FindBestTargetEncoded` (`unit.c`) — the deterministic auto-target
/// pick: a seen, non-allied, priority enemy is returned; allied / unseen / self are excluded.
@Suite("Unit_FindBestTarget")
struct TargetFinderTests {
    /// A used+allocated unit at `packed`, owned by `house`.
    private func place(_ s: inout GameState, _ type: UnitType, _ house: UInt8, _ packed: UInt16) -> Int {
        let slot = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.flags.insert([.used, .allocated])
        s.units[slot].o.position = Tile32.unpack(packed)
        s.units[slot].o.hitpoints = UnitInfo[type].o.hitpoints
        return slot
    }

    private func world() -> GameState {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        return s
    }

    @Test("returns the seen, non-allied enemy unit")
    func picksEnemy() {
        var s = world()
        let attacker = place(&s, .tank, 0, 1040)
        let target = place(&s, .tank, 2, 1042)
        s.units[target].o.seenByHouses = 0xFF   // seen by all houses

        let finder = TargetFinder()
        let encoded = finder.findBestTargetEncoded(slot: attacker, mode: 0, in: &s)
        #expect(encoded == s.indexEncode(s.units[target].o.index, type: .unit))
    }

    @Test("an unseen enemy is not targeted")
    func unseenIgnored() {
        var s = world()
        let attacker = place(&s, .tank, 0, 1040)
        let target = place(&s, .tank, 2, 1042)
        s.units[target].o.seenByHouses = 0   // not seen by anyone

        #expect(TargetFinder().findBestTargetEncoded(slot: attacker, mode: 0, in: &s) == 0)
    }

    @Test("an allied unit is not targeted")
    func alliedIgnored() {
        var s = world()
        let attacker = place(&s, .tank, 0, 1040)
        let friend = place(&s, .tank, 0, 1042)   // same house
        s.units[friend].o.seenByHouses = 0xFF

        #expect(TargetFinder().findBestTargetEncoded(slot: attacker, mode: 0, in: &s) == 0)
    }

    @Test("the higher-priority (closer) of two enemies is chosen")
    func picksHigherPriority() {
        var s = world()
        let attacker = place(&s, .tank, 0, 1040)
        let near = place(&s, .tank, 2, 1041)
        let far = place(&s, .tank, 2, 1040 + 20)
        s.units[near].o.seenByHouses = 0xFF
        s.units[far].o.seenByHouses = 0xFF

        // Same type ⇒ priority scales inversely with distance, so the nearer enemy wins.
        let encoded = TargetFinder().findBestTargetEncoded(slot: attacker, mode: 0, in: &s)
        #expect(encoded == s.indexEncode(s.units[near].o.index, type: .unit))
    }
}
