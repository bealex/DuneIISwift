import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// `Sandworm_GetBestTarget` (0x36) + the link-validity natives `Unknown2BD5` (0x37) / `Unknown0288` (0x3B).
@Suite("Sandworm + link-validity natives")
struct SandwormNativesTests {
    /// Force terrain via groundTileID: 0 → sand, 49 → spice (both `isSand`), 1 → partialRock (not sand).
    private func tileIDs() -> TileIDs {
        var t = TileIDs(); t.landscape = 0; t.builtSlab = 1000; t.bloom = 2000; t.wall = 3000; t.veiled = 4000
        return t
    }

    private func base() -> GameState {
        var s = GameState(); s.tileIDs = tileIDs()
        _ = s.houseAllocate(index: 0); _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100; s.houses[2].unitCountMax = 100
        return s
    }

    private func addUnit(_ s: inout GameState, _ type: UnitType, house: UInt8, at packed: UInt16, sand: Bool = true)
        -> Int
    {
        let slot = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(packed)
        s.map[Int(packed)].groundTileID = sand ? 0 : 1
        s.map[Int(packed)].isUnveiled = true
        return slot
    }

    @Test("sandworm picks a prey standing on revealed sand, skips one on rock")
    func sandwormBestTarget() {
        var s = base()
        let worm = addUnit(&s, .sandworm, house: 0, at: Tile32.packXY(x: 20, y: 20))
        let onSand = addUnit(&s, .trike, house: 2, at: Tile32.packXY(x: 22, y: 20), sand: true)
        let targets = TargetFinder()
        let best = targets.sandwormFindBestTarget(slot: worm, in: s)
        #expect(best == onSand)

        // Move the only prey onto rock → no valid target.
        s.map[Int(Tile32.packXY(x: 22, y: 20))].groundTileID = 1  // partialRock (not sand)
        #expect(targets.sandwormFindBestTarget(slot: worm, in: s) == nil)
    }

    @Test("Unknown2BD5: a mutual same-house link is valid (1); a broken link is cleared (0)")
    func unknown2BD5() {
        var s = base()
        let funcs = UnitScriptFunctions(unitPrimitives: DefaultUnitPrimitives())
        let a = addUnit(&s, .carryall, house: 0, at: Tile32.packXY(x: 20, y: 20))
        let b = addUnit(&s, .harvester, house: 0, at: Tile32.packXY(x: 21, y: 20))
        let aEnc = s.indexEncode(s.units[a].o.index, type: .unit)
        let bEnc = s.indexEncode(s.units[b].o.index, type: .unit)
        s.units[a].o.script.variables[4] = bEnc
        s.units[b].o.script.variables[4] = aEnc  // mutual link, same house
        #expect(funcs.unknown2BD5(slot: a, in: &s) == 1)

        // Break the back-link → invalid, cleared to 0.
        s.units[b].o.script.variables[4] = 0
        #expect(funcs.unknown2BD5(slot: a, in: &s) == 0)
        #expect(s.units[a].o.script.variables[4] == 0)  // dropped
    }

    @Test("eating a unit starts the swallow explosion + plays the worm voice")
    func eatStartsSwallowExplosion() {
        let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })
        var s = base()
        s.playerHouseID = 0
        // Worm and prey on the same tile ⇒ distance 0, so the worm (fireDistance 0) bites this tick.
        let pos = Tile32.packXY(x: 20, y: 20)
        let worm = addUnit(&s, .sandworm, house: 0, at: pos)
        s.units[worm].amount = 3  // remaining capacity (>1 ⇒ survives the bite)
        let prey = addUnit(&s, .trike, house: 2, at: pos)
        s.units[worm].targetAttack = s.indexEncode(s.units[prey].o.index, type: .unit)
        s.units[worm].fireDelay = 0

        let combat = UnitCombat(movement: UnitMovement(scriptInfo: info))
        _ = combat.fire(slot: worm, in: &s)

        #expect(!s.units[prey].o.flags.contains(.used))  // prey swallowed (removed from play)
        // The EXPLOSION_SANDWORM_SWALLOW "gulp" animation is now started at the worm (was a SEAM).
        #expect(s.explosions.contains { $0.active && $0.tableIndex == ExplosionType.sandwormSwallow.rawValue })
        #expect(s.soundEvents.contains { $0.sound == SoundID(63) })  // WORMET3P (Voice_PlayAtTile 63)
        #expect(s.units[worm].amount == 2)  // capacity decremented; worm lives on
    }

    @Test("Unknown0288: a live structure index → 0, an empty index → 1")
    func unknown0288() {
        var s = base()
        let general = GeneralScriptFunctions()
        let r = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[r].o.houseID = 0
        let enc = s.indexEncode(s.structures[r].o.index, type: .structure)
        #expect(general.unknown0288(index: enc, in: s) == 0)  // resolves to a live structure
        #expect(general.unknown0288(index: 0, in: s) == 1)  // resolves to nothing
    }
}
