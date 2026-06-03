import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Spice-bloom destruction — when a unit drives onto a spice bloom it detonates (`Map_Bloom_ExplodeSpice`,
/// `map.c:669`): the bloom sprite is removed (the tile reverts to its base sand, then spreads spice) and the
/// spice circle fills. The regression this guards: the loader used to overwrite `mapBaseTileID` with the
/// bloom sprite, so the revert restored the bloom and it never visually disappeared (`loadMapBlooms`).
///
/// "Attacking the bloom" and "moving into it" are the same interaction in 1.07: a bloom isn't a directly
/// targetable object, so an attack-move simply walks the unit onto it (the arrival path below). The
/// explosion→bloom-on-sand path is a separate documented seam (`GameState+Explosion`).
@Suite("Spice-bloom destruction")
struct BloomInteractionTests {
    private let info = ScriptInfo(program: [ UInt16 ](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })
    private static let bloomID: UInt16 = 200  // synthetic non-zero bloom sprite id
    private static let sandID: UInt16 = 100  // the generated base under the bloom

    private func base() -> (GameState, UnitMovement) {
        var s = GameState(random256Seed: 0x1234)
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        s.tileIDs.bloom = Self.bloomID
        return (s, UnitMovement(scriptInfo: info))
    }

    /// Set tile `packed` up like a freshly-loaded bloom: it *shows* the bloom but its base is sand.
    private func makeBloom(_ s: inout GameState, _ packed: UInt16) {
        s.map[Int(packed)].groundTileID = Self.bloomID
        s.mapBaseTileID[Int(packed)] = Self.sandID
    }

    @Test("detonating a bloom removes the bloom sprite (reverts toward the sand base, not the bloom)")
    func detonationRemovesBloom() {
        var (s, move) = base()
        let packed = Tile32.packXY(x: 30, y: 30)
        makeBloom(&s, packed)
        #expect(s.map[Int(packed)].groundTileID == Self.bloomID)  // shows the bloom before

        move.mapBloomExplodeSpice(packed: packed, houseID: 0, in: &s)

        #expect(s.map[Int(packed)].groundTileID != Self.bloomID)  // the bloom is gone (no iconMap ⇒ sand 100)
    }

    @Test("a ground unit driving onto a bloom detonates and removes it")
    func movingOntoBloomRemovesIt() {
        var (s, move) = base()
        let from = Tile32.packXY(x: 20, y: 20)
        let onto = Tile32.packXY(x: 21, y: 20)  // one tile east — the bloom
        makeBloom(&s, onto)

        let slot = s.unitAllocate(index: 0, type: UInt8(UnitType.trike.rawValue), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(from)
        s.units[slot].o.hitpoints = 100
        s.units[slot].currentDestination = Tile32.unpack(onto)
        s.units[slot].distanceToDestination = 0x7FFF
        let dir = Tile32.direction(from: Tile32.unpack(from), to: Tile32.unpack(onto))
        move.unit.setOrientation(&s.units[slot], orientation: dir, rotateInstantly: true, level: 0)
        s.unitUpdateMap(1, slot)

        // One full-tile step east lands the unit on the bloom → arrival → Map_Bloom_ExplodeSpice.
        _ = move.move(slot: slot, distance: 256, in: &s)

        #expect(s.map[Int(onto)].groundTileID != Self.bloomID)  // the bloom was detonated + removed
    }

    /// The "shoot the bloom" path: an explosion's VM queues `pendingBloomDetonations` (a World seam), and
    /// the loop drains it after `explosionTick`, running `Map_Bloom_ExplodeSpice` — reverting the bloom +
    /// spreading spice. Here we seed the queue (what the VM's BLOOM command would have done) and tick.
    @Test("the loop drains a queued bloom detonation (reverts the bloom + spreads spice)")
    func tickDrainsBloomDetonation() {
        var sim = Simulation(scriptInfo: info, tickExplosions: true)
        sim.state.playerHouseID = 0
        _ = sim.state.houseAllocate(index: 0)
        sim.state.tileIDs.bloom = Self.bloomID
        let p = Int(Tile32.packXY(x: 30, y: 30))
        sim.state.map[p].groundTileID = Self.bloomID
        sim.state.mapBaseTileID[p] = Self.sandID
        sim.state.pendingBloomDetonations = [ UInt16(p) ]

        sim.tick()

        #expect(sim.state.map[p].groundTileID != Self.bloomID)  // detonated → reverted off the bloom
        #expect(sim.state.pendingBloomDetonations.isEmpty)  // drained
    }
}
