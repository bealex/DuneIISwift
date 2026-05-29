import Testing
import DuneIIContracts
@testable import DuneIIWorld

/// Tests for the object pools + the pool-dependent `Tools_Index_*` functions on `GameState`. These
/// transcribe OpenDUNE's `src/pool/*.c` + the deferred `src/tools.c` index helpers; the tests pin the
/// observable behaviour (band allocation, find iteration/filtering, special structure slots, the
/// encode/decode round-trips).
@Suite("GameState pools + index helpers")
struct GameStateTests {
    private func u(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }
    private func st(_ t: StructureType) -> UInt8 { UInt8(t.rawValue) }

    @Test("unit allocate uses the type's index band and bumps the house count")
    func unitAllocate() {
        var s = GameState()
        s.houses[0].unitCountMax = 100
        let a = s.unitAllocate(index: 0, type: u(.infantry), houseID: 0)   // band [22, 101]
        let b = s.unitAllocate(index: 0, type: u(.infantry), houseID: 0)
        #expect(a == 22)
        #expect(b == 23)
        #expect(s.units[22].o.flags.contains(.used))
        #expect(s.units[22].o.flags.contains(.allocated))
        #expect(s.units[22].o.flags.contains(.isUnit))
        #expect(s.units[22].o.linkedID == 0xFF)
        #expect(s.units[22].route[0] == 0xFF)
        #expect(s.houses[0].unitCount == 2)
        #expect(s.unitFindArray.count == 2)
    }

    @Test("house unit cap blocks ground units but not wingers/slitherers")
    func unitCap() {
        var s = GameState()
        s.houses[0].unitCountMax = 0   // already at cap
        #expect(s.unitAllocate(index: 0, type: u(.tank), houseID: 0) == nil)   // ground unit blocked
        #expect(s.unitAllocate(index: 0, type: u(.carryall), houseID: 0) != nil) // winger bypasses
        let worm = s.unitAllocate(index: 0, type: u(.sandworm), houseID: 0)     // slither bypasses
        #expect(worm != nil)
        #expect(s.units[worm!].amount == 3)   // sandworm starts with amount 3
    }

    @Test("structure allocate: specials route to fixed slots, normals take soft slots")
    func structureAllocate() {
        var s = GameState()
        let wall = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.wall))
        #expect(wall == Int(Pool.structureIndexWall))      // 79
        #expect(s.structureFindArray.isEmpty)              // specials never enter the find array
        let slab = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.slab2x2))
        #expect(slab == Int(Pool.structureIndexSlab2x2))   // 80
        let refinery = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.refinery))
        #expect(refinery == 0)
        #expect(s.structureFindArray == [0])
        #expect(s.structures[0].o.flags.contains(.used))
        #expect(!s.structures[0].o.flags.contains(.isUnit))   // structures are not units
    }

    @Test("unitFind iterates allocated units and filters by house/type")
    func unitFind() {
        var s = GameState()
        s.houses[0].unitCountMax = 100
        s.houses[1].unitCountMax = 100
        _ = s.unitAllocate(index: 0, type: u(.infantry), houseID: 0)
        _ = s.unitAllocate(index: 0, type: u(.trike), houseID: 1)

        var all = PoolFind(); var found: [Int] = []
        while let i = s.unitFind(&all) { found.append(i) }
        #expect(found == [22, 23])

        var byHouse = PoolFind(houseID: 1); var h1: [Int] = []
        while let i = s.unitFind(&byHouse) { h1.append(i) }
        #expect(h1.count == 1)
        #expect(s.units[h1[0]].o.houseID == 1)

        var byType = PoolFind(type: UInt16(UnitType.trike.rawValue)); var trikes: [Int] = []
        while let i = s.unitFind(&byType) { trikes.append(i) }
        #expect(trikes == [23])
    }

    @Test("Tools_Index_* round-trip through the pools (unit / structure / tile)")
    func toolsIndex() {
        var s = GameState()
        s.houses[0].unitCountMax = 100
        let unit = s.unitAllocate(index: 0, type: u(.infantry), houseID: 0)!
        s.units[unit].o.position = Tile32(x: 0x0A80, y: 0x0B80)

        let enc = s.indexEncode(UInt16(unit), type: .unit)
        #expect(Tools.indexType(enc) == .unit)
        #expect(Tools.indexDecode(enc) == UInt16(unit))
        #expect(s.indexIsValid(enc))
        #expect(s.indexGetUnit(enc) == unit)
        #expect(s.indexGetStructure(enc) == nil)
        #expect(s.indexGetObject(enc) == .unit(unit))
        #expect(s.indexGetTile(enc) == Tile32(x: 0x0A80, y: 0x0B80))

        let structure = s.structureAllocate(index: Pool.structureIndexInvalid, type: st(.refinery))!
        s.structures[structure].o.position = Tile32(x: 0x0100, y: 0x0100)
        let encS = s.indexEncode(UInt16(structure), type: .structure)
        #expect(s.indexGetStructure(encS) == structure)
        #expect(s.indexGetObject(encS) == .structure(structure))
        let diff = StructureLayoutInfo[StructureInfo[.refinery].layout].tileDiff
        #expect(s.indexGetTile(encS) == Tile32.addDiff(Tile32(x: 0x0100, y: 0x0100), diff))

        let packed = Tile32.packXY(x: 10, y: 20)
        let encT = s.indexEncode(packed, type: .tile)
        #expect(Tools.indexType(encT) == .tile)
        #expect(Tools.indexDecode(encT) == packed)
        #expect(s.indexGetTile(encT) == Tile32.unpack(packed))

        #expect(!s.indexIsValid(0))                  // 0 is never valid
        let unallocated = s.indexEncode(99, type: .unit)   // slot 99 not allocated
        #expect(unallocated == 0)
    }

    @Test("unitRecount rebuilds the find array and per-house counts")
    func recount() {
        var s = GameState()
        _ = s.houseAllocate(index: 0)
        s.houses[0].unitCountMax = 100
        _ = s.unitAllocate(index: 0, type: u(.infantry), houseID: 0)   // slot 22

        // A unit placed directly into a slot (e.g. by a loader) is missing from the find array.
        s.units[50].o.flags = [.used, .allocated, .isUnit]
        s.units[50].o.houseID = 0

        s.unitRecount()
        #expect(s.unitFindArray == [22, 50])
        #expect(s.houses[0].unitCount == 2)
    }

    @Test("house + team allocate")
    func houseTeamAllocate() {
        var s = GameState()
        #expect(s.houseAllocate(index: 0) == 0)
        #expect(s.houses[0].flags.contains(.used))
        #expect(s.houses[0].starportLinkedID == 0xFFFF)
        #expect(s.houseAllocate(index: 0) == nil)   // already used

        let t = s.teamAllocate(index: Pool.teamIndexInvalid)
        #expect(t == 0)
        #expect(s.teams[0].flags.contains(.used))
        #expect(s.teamFindArray == [0])
    }
}
