import DuneIIContracts
import DuneIIWorld
import Testing

@testable import DuneIISimulation

/// Decision-trace coverage for `Structure_HouseUnderAttack` (`structure.c:1933`) and its sole trigger site,
/// `Map_MakeExplosion` (`map.c:500`). The "your base is under attack" feedback (id 48) must fire only on a
/// real combat impact to a *player* structure, gated by `timerStructureAttack` — never on degradation,
/// power-shortfall HP clamping, or partial-slab placement (the bug these tests pin: those paths reach
/// `structureDamage` directly and must leave `pendingFeedback` empty).
@Suite("Structure_HouseUnderAttack")
struct HouseUnderAttackTests {
    let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    /// Allocate a structure for `house`, give it full HP, and stamp it on the map at `packed` so
    /// `structureGetByPackedTile` resolves it (mirrors the minimal placement used by other sim tests).
    private func place(_ s: inout GameState, _ type: StructureType, house: UInt8, at packed: UInt16) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[type].o.hitpoints
        s.structures[slot].o.position = Tile32.unpack(packed)
        s.map[Int(packed)].hasStructure = true
        s.map[Int(packed)].index = UInt8(slot + 1)
        return slot
    }

    private func setup(player: UInt8 = 0) -> (GameState, UnitCombat) {
        var s = GameState(random256Seed: 0x12345)
        s.playerHouseID = player
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    // MARK: Structure_HouseUnderAttack directly

    @Test("player house hit: raises feedback 48 and arms the 8-tick timer")
    func playerRaisesFeedback() {
        var (s, _) = setup(player: 0)
        s.structureHouseUnderAttack(0)
        #expect(s.pendingFeedback == [ 48 ])
        #expect(s.houses[0].timerStructureAttack == 8)
        #expect(s.houses[0].flags.contains(.doneFullScaleAttack))
    }

    @Test("player house: a second hit while the timer is armed raises no new feedback")
    func playerTimerGates() {
        var (s, _) = setup(player: 0)
        s.structureHouseUnderAttack(0)
        s.pendingFeedback.removeAll()  // simulate the host draining last tick's feedback
        s.structureHouseUnderAttack(0)  // timer still 8 ⇒ suppressed
        #expect(s.pendingFeedback.isEmpty)
    }

    @Test("AI house hit: flips doneFullScaleAttack but never raises the player feedback")
    func aiNoFeedback() {
        var (s, _) = setup(player: 0)
        s.structureHouseUnderAttack(2)  // house 2 is the AI
        #expect(s.pendingFeedback.isEmpty)
        #expect(s.houses[2].flags.contains(.doneFullScaleAttack))
        #expect(s.houses[2].timerStructureAttack == 0)
        // A second AI hit short-circuits on the one-shot flag (no crash, still no feedback).
        s.structureHouseUnderAttack(2)
        #expect(s.pendingFeedback.isEmpty)
    }

    @Test("HOUSE_INVALID (0xFF) is a no-op")
    func invalidHouse() {
        var (s, _) = setup(player: 0)
        s.structureHouseUnderAttack(0xFF)
        #expect(s.pendingFeedback.isEmpty)
    }

    // MARK: through Map_MakeExplosion (the real trigger site)

    @Test("explosion on a player structure raises the under-attack feedback")
    func explosionOnPlayerStructure() {
        var (s, combat) = setup(player: 0)
        let packed: UInt16 = 20 * 64 + 20
        _ = place(&s, .windtrap, house: 0, at: packed)
        combat.movement.mapMakeExplosion(type: 0, position: Tile32.unpack(packed), hitpoints: 30, origin: 0, in: &s)
        #expect(s.pendingFeedback == [ 48 ])
        #expect(s.houses[0].timerStructureAttack == 8)
    }

    @Test("explosion on an AI structure raises no player feedback")
    func explosionOnAIStructure() {
        var (s, combat) = setup(player: 0)
        let packed: UInt16 = 30 * 64 + 30
        _ = place(&s, .windtrap, house: 2, at: packed)
        combat.movement.mapMakeExplosion(type: 0, position: Tile32.unpack(packed), hitpoints: 30, origin: 0, in: &s)
        #expect(s.pendingFeedback.isEmpty)
    }

    @Test("a pure visual blast (hitpoints 0) on a player structure raises nothing")
    func visualBlastNoFeedback() {
        var (s, combat) = setup(player: 0)
        let packed: UInt16 = 20 * 64 + 20
        _ = place(&s, .windtrap, house: 0, at: packed)
        combat.movement.mapMakeExplosion(type: 0, position: Tile32.unpack(packed), hitpoints: 0, origin: 0, in: &s)
        #expect(s.pendingFeedback.isEmpty)
    }

    // MARK: the bug — non-combat HP loss must NOT alert

    @Test("direct structureDamage (degrade / power / placement) raises no under-attack feedback")
    func degradeDoesNotAlert() {
        var (s, _) = setup(player: 0)
        let slot = place(&s, .windtrap, house: 0, at: 20 * 64 + 20)
        // The campaign-degrade and power-shortfall paths call structureDamage directly, bypassing
        // Map_MakeExplosion — so the player's HP drops but no alert is raised.
        _ = s.structureDamage(slot, damage: 5, range: 0)
        #expect(s.structures[slot].o.hitpoints < StructureInfo[.windtrap].o.hitpoints)
        #expect(s.pendingFeedback.isEmpty)
    }
}
