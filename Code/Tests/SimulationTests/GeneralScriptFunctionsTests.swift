import DuneIIContracts
import DuneIIWorld
import Testing

@testable import DuneIISimulation

/// Per-function coverage for the `Script_General_*` natives (`GeneralScriptFunctions`). Each function is
/// exercised over many cases; values are checked against the OpenDUNE logic in `src/script/general.c`
/// (the RNG/distance/index pieces they wrap are themselves golden-verified against the oracle).
@Suite("Script_General_* natives")
struct GeneralScriptFunctionsTests {
    let gen = GeneralScriptFunctions()

    private func u(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }

    private func st(_ t: StructureType) -> UInt8 { UInt8(t.rawValue) }

    /// A GameState with houses 0 (Harkonnen) and 2 (Ordos) allocated and a high unit cap.
    private func makeState() -> GameState {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        return s
    }

    @Test("noOperation returns 0")
    func noOperation() { #expect(gen.noOperation() == 0) }

    @Test("delay divides ticks by 5")
    func delay() {
        #expect(gen.delay(ticks: 0) == 0)
        #expect(gen.delay(ticks: 4) == 0)
        #expect(gen.delay(ticks: 5) == 1)
        #expect(gen.delay(ticks: 12) == 2)
        #expect(gen.delay(ticks: 255) == 51)
    }

    @Test("delayRandom = Random256 * max / 256 / 5, drawing one RNG byte")
    func delayRandom() {
        for (seed, maxTicks) in [ (UInt32(0), UInt16(100)), (42, 255), (0xC0DE, 50), (7, 1000) ] {
            var probe = GameState(random256Seed: seed)
            let r = probe.random256.next()
            let expected = UInt16(UInt32(r) * UInt32(maxTicks) / 256) / 5
            var s = GameState(random256Seed: seed)
            #expect(gen.delayRandom(maxTicks: maxTicks, in: &s) == expected)
        }
    }

    @Test("randomRange wraps RandomLCG.range")
    func randomRange() {
        for seed in [ UInt16(0), 1, 0x1234, 0x7FFF ] {
            for (lo, hi) in [ (UInt16(0), UInt16(100)), (1, 6), (5, 5), (0, 255) ] {
                var probe = GameState(randomLCGSeed: seed)
                let expected = probe.randomLCG.range(lo, hi)
                var s = GameState(randomLCGSeed: seed)
                #expect(gen.randomRange(min: lo, max: hi, in: &s) == expected)
            }
        }
    }

    @Test("getDistanceToTile: distance for a valid tile index, 0xFFFF for invalid")
    func getDistanceToTile() {
        let s = makeState()
        let from = Tile32.unpack(20 * 64 + 20)
        for packed: UInt16 in [ 0, 100, 1300, 2080, 4000 ] {
            let encoded = s.indexEncode(packed, type: .tile)
            let expected = Tile32.distance(from: from, to: s.indexGetTile(encoded))
            #expect(gen.getDistanceToTile(from: from, encoded: encoded, in: s) == expected)
        }
        #expect(gen.getDistanceToTile(from: from, encoded: 0, in: s) == 0xFFFF)  // invalid
    }

    @Test("getDistanceToObject: unit/tile to its tile, structure to its facing edge, invalid ⇒ 0xFFFF")
    func getDistanceToObject() {
        var s = makeState()
        let from = Tile32.unpack(20 * 64 + 20)

        #expect(gen.getDistanceToObject(from: from, encoded: 0, in: s) == 0xFFFF)  // invalid

        // A tile target ⇒ distance to that tile (same as getDistanceToTile).
        let tileEnc = s.indexEncode(30 * 64 + 30, type: .tile)
        #expect(
            gen.getDistanceToObject(from: from, encoded: tileEnc, in: s)
                == Tile32.distance(from: from, to: s.indexGetTile(tileEnc))
        )

        // A unit target ⇒ distance to the unit's tile.
        let unit = s.unitAllocate(index: 0, type: u(.tank), houseID: 2)!
        s.units[unit].o.position = Tile32.unpack(25 * 64 + 25)
        let unitEnc = s.indexEncode(s.units[unit].o.index, type: .unit)
        #expect(
            gen.getDistanceToObject(from: from, encoded: unitEnc, in: s)
                == Tile32.distance(from: from, to: s.units[unit].o.position)
        )

        // A structure target ⇒ distance to the edge tile facing `from` (≠ the naive origin distance).
        let str = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.refinery))!
        s.structures[str].o.houseID = 0
        s.structures[str].o.position = Tile32.unpack(28 * 64 + 28)
        let strEnc = s.indexEncode(s.structures[str].o.index, type: .structure)
        let dir8 = Orientation.to8(UInt8(bitPattern: Tile32.direction(from: from, to: s.structures[str].o.position)))
        let edge = StructureLayoutInfo[StructureInfo[.refinery].layout].edgeTiles[Int((dir8 &+ 4) & 7)]
        let expected = Tile32.distance(from: from, to: Tile32.unpack(s.structures[str].o.position.packed &+ edge))
        #expect(gen.getDistanceToObject(from: from, encoded: strEnc, in: s) == expected)
    }

    @Test("isEnemy: different house ⇒ 1, same ⇒ 0, deviation-aware, invalid ⇒ 0")
    func isEnemy() {
        var s = makeState()
        let mine = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let enemy = s.unitAllocate(index: 0, type: u(.tank), houseID: 2)!
        let enemyStruct = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.refinery))!
        s.structures[enemyStruct].o.houseID = 2

        #expect(gen.isEnemy(currentHouseID: 0, encoded: s.indexEncode(UInt16(mine), type: .unit), in: s) == 0)
        #expect(gen.isEnemy(currentHouseID: 0, encoded: s.indexEncode(UInt16(enemy), type: .unit), in: s) == 1)
        #expect(
            gen.isEnemy(currentHouseID: 0, encoded: s.indexEncode(UInt16(enemyStruct), type: .structure), in: s) == 1
        )
        #expect(gen.isEnemy(currentHouseID: 0, encoded: 0, in: s) == 0)  // invalid index

        // A deviated unit counts as Ordos (house 2), so it reads as an enemy of house 0.
        s.units[mine].deviated = 1
        #expect(gen.isEnemy(currentHouseID: 0, encoded: s.indexEncode(UInt16(mine), type: .unit), in: s) == 1)
    }

    @Test("isFriendly: allied on-map ⇒ 1, enemy ⇒ 0xFFFF, off-map/invalid ⇒ 0")
    func isFriendly() {
        var s = makeState()
        let mine = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let enemy = s.unitAllocate(index: 0, type: u(.tank), houseID: 2)!

        #expect(gen.isFriendly(currentHouseID: 0, encoded: s.indexEncode(UInt16(mine), type: .unit), in: s) == 1)
        #expect(gen.isFriendly(currentHouseID: 0, encoded: s.indexEncode(UInt16(enemy), type: .unit), in: s) == 0xFFFF)
        #expect(gen.isFriendly(currentHouseID: 0, encoded: 0, in: s) == 0)  // no object

        s.units[mine].o.flags.insert(.isNotOnMap)
        #expect(gen.isFriendly(currentHouseID: 0, encoded: s.indexEncode(UInt16(mine), type: .unit), in: s) == 0)
    }

    @Test("getIndexType / decodeIndex echo the encoding, 0xFFFF when invalid")
    func indexTypeAndDecode() {
        var s = makeState()
        let unit = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        let structure = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.refinery))!
        let unitEnc = s.indexEncode(UInt16(unit), type: .unit)
        let structEnc = s.indexEncode(UInt16(structure), type: .structure)
        let tileEnc = s.indexEncode(1300, type: .tile)

        #expect(gen.getIndexType(encoded: unitEnc, in: s) == 2)  // IT_UNIT
        #expect(gen.getIndexType(encoded: structEnc, in: s) == 3)  // IT_STRUCTURE
        #expect(gen.getIndexType(encoded: tileEnc, in: s) == 1)  // IT_TILE
        #expect(gen.getIndexType(encoded: 0, in: s) == 0xFFFF)  // invalid

        #expect(gen.decodeIndex(encoded: unitEnc, in: s) == UInt16(unit))
        #expect(gen.decodeIndex(encoded: structEnc, in: s) == UInt16(structure))
        #expect(gen.decodeIndex(encoded: 0, in: s) == 0xFFFF)
    }

    @Test("getOrientation: a unit's base orientation, else 128")
    func getOrientation() {
        var s = makeState()
        let unit = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)!
        s.units[unit].orientation[0].current = 64
        #expect(gen.getOrientation(encoded: s.indexEncode(UInt16(unit), type: .unit), in: s) == 64)

        s.units[unit].orientation[0].current = -1  // sign-extends to 0xFFFF
        #expect(gen.getOrientation(encoded: s.indexEncode(UInt16(unit), type: .unit), in: s) == 0xFFFF)

        let structEnc = s.indexEncode(0, type: .structure)
        #expect(gen.getOrientation(encoded: structEnc, in: s) == 128)  // not a unit
    }

    @Test("getLinkedUnitType: the linked unit's type, or 0xFFFF")
    func getLinkedUnitType() {
        var s = makeState()
        let linked = s.unitAllocate(index: 0, type: u(.trike), houseID: 0)!
        #expect(gen.getLinkedUnitType(linkedID: UInt8(linked), in: s) == UInt16(u(.trike)))
        #expect(gen.getLinkedUnitType(linkedID: 0xFF, in: s) == 0xFFFF)
    }

    @Test("unitCount: on-map units of the house, filtered by type")
    func unitCount() {
        var s = makeState()
        _ = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)
        _ = s.unitAllocate(index: 0, type: u(.tank), houseID: 0)
        _ = s.unitAllocate(index: 0, type: u(.trike), houseID: 0)
        _ = s.unitAllocate(index: 0, type: u(.tank), houseID: 2)

        #expect(gen.unitCount(houseID: 0, type: 0xFFFF, in: s) == 3)
        #expect(gen.unitCount(houseID: 0, type: UInt16(u(.tank)), in: s) == 2)
        #expect(gen.unitCount(houseID: 0, type: UInt16(u(.trike)), in: s) == 1)
        #expect(gen.unitCount(houseID: 2, type: 0xFFFF, in: s) == 1)
        #expect(gen.unitCount(houseID: 1, type: 0xFFFF, in: s) == 0)
    }
}
