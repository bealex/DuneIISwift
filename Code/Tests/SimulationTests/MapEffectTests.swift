import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Slice 4 — the deviator-gas area effect (`Map_DeviateArea`), the spice-bloom detonation
/// (`Map_Bloom_ExplodeSpice`), and the `Map_FillCircleWithSpice` map primitive.
@Suite("Map area effects — deviator + spice bloom")
struct MapEffectTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base(seed: UInt32 = 0x12345) -> (GameState, UnitMovement) {
        var s = GameState(random256Seed: seed)
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        _ = s.houseAllocate(index: 1); s.houses[1].unitCountMax = 100
        return (s, UnitMovement(scriptInfo: info))
    }

    private func addOnMap(_ s: inout GameState, _ type: UnitType, house: UInt8, at packed: UInt16, index: UInt16) -> Int {
        let slot = s.unitAllocate(index: index, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(packed)
        s.units[slot].o.hitpoints = 100
        s.unitUpdateMap(1, slot)
        return slot
    }

    // MARK: - Map_DeviateArea

    @Test("a deviator gas cloud starts an explosion and attempts deviation on each in-range unit only")
    func deviateArea() {
        var (s, move) = base()
        _ = addOnMap(&s, .trike, house: 0, at: Tile32.packXY(x: 20, y: 20), index: 0)   // in range (dist 0)
        let far = addOnMap(&s, .trike, house: 0, at: Tile32.packXY(x: 60, y: 60), index: 1)  // out of range

        var probe = s.random256
        move.mapDeviateArea(type: UInt16(ExplosionType.deviatorGas.rawValue),
                            position: Tile32.unpack(Tile32.packXY(x: 20, y: 20)), radius: 32, houseID: 1, in: &s)

        // Exactly one RNG draw — the in-range unit's deviate attempt. The far unit is skipped by the
        // radius gate before any draw (deviation success itself is covered by UnitCombatTests).
        _ = probe.next()
        #expect(s.random256.next() == probe.next())
        #expect(s.units[far].deviated == 0)
        #expect(s.explosions.contains { $0.active })   // the gas-cloud explosion started
    }

    @Test("a deviator missile detonating in flight deviates the area and is removed")
    func deviatorMissileArrival() {
        // Seed chosen so the area's lone RNG draw lands under the victim's deviation threshold.
        var (s, move) = base(seed: 0x9)
        let missile = s.unitAllocate(index: 0, type: UInt8(UnitType.missileDeviator.rawValue), houseID: 1)!
        s.units[missile].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        s.units[missile].o.hitpoints = 50
        s.units[missile].fireDelay = 0
        s.units[missile].currentDestination = Tile32.unpack(Tile32.packXY(x: 11, y: 10))
        move.unit.setOrientation(&s.units[missile], orientation: 64, rotateInstantly: true, level: 0)

        _ = addOnMap(&s, .trike, house: 0, at: Tile32.packXY(x: 11, y: 10), index: 1)

        let ret = move.move(slot: missile, distance: 255, in: &s)
        #expect(ret)
        #expect(!s.units[missile].o.flags.contains(.used))   // missile consumed
        #expect(s.explosions.contains { $0.active })         // deviator-gas explosion started
    }

    // MARK: - Map_Bloom_ExplodeSpice

    @Test("detonating a spice bloom removes the unit on it, reverts the tile, and fires the tremor")
    func bloomExplodeSpice() {
        var (s, move) = base()
        let packed = Tile32.packXY(x: 30, y: 30)
        s.map[Int(packed)].groundTileID = s.tileIDs.bloom
        s.mapBaseTileID[Int(packed)] = 0x8000 | 0x42         // some base sand tile id
        let unit = addOnMap(&s, .trike, house: 0, at: packed, index: 0)

        move.mapBloomExplodeSpice(packed: packed, houseID: 0, in: &s)

        #expect(!s.units[unit].o.flags.contains(.used))      // Unit_Remove fired
        #expect(s.map[Int(packed)].groundTileID == 0x42)     // ground reverted to mapBaseTileID & 0x1FF
        #expect(s.explosions.contains { $0.active })         // SPICE_BLOOM_TREMOR
    }

    // MARK: - Map_FillCircleWithSpice

    @Test("fillCircleWithSpice is a no-op at radius 0 and draws no RNG")
    func fillCircleRadiusZero() {
        var (s, move) = base()
        var probe = s.random256   // value-type copy, captured before the call
        move.map.fillCircleWithSpice(Tile32.packXY(x: 30, y: 30), radius: 0, in: &s)
        // No draws happened ⇒ live RNG and the copy are in the same state ⇒ next draws agree.
        #expect(s.random256.next() == probe.next())
    }

    @Test("fillCircleWithSpice draws one RNG per circle-edge tile")
    func fillCircleDrawsEdgeRNG() {
        var (s, move) = base()
        // With no iconMap loaded, changeSpiceAmount can't retile; the observable here is the RNG cadence:
        // exactly one Random256 per edge tile of the radius-r circle (interior tiles draw none).
        var probe = s.random256
        var edgeTiles = 0
        let r = 2, cx = 30, cy = 30, center = Tile32.packXY(x: 30, y: 30)
        for i in -r ... r { for j in -r ... r {
            let p = Tile32.packXY(x: UInt16(cx + j), y: UInt16(cy + i))
            if Tile32.distancePacked(center, p) == UInt16(r) { edgeTiles += 1 }
        } }
        move.map.fillCircleWithSpice(center, radius: UInt16(r), in: &s)
        for _ in 0 ..< edgeTiles { _ = probe.next() }   // advance the copy the expected number of draws
        #expect(s.random256.next() == probe.next())     // ⇒ exactly edgeTiles draws happened
        #expect(edgeTiles > 0)
    }
}
