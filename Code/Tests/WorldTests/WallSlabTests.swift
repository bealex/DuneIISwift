import DuneIIContracts
import Testing

@testable import DuneIIWorld

/// Slab + wall placement — the map-tile "structures" that `Structure_Place` stamps and then frees. Before
/// this they were allocated but never drawn (no script ever stamps a slab/wall). See `GameState+WallSlab`.
@Suite("Slab + wall placement")
struct WallSlabTests {
    private func state() -> GameState {
        var s = GameState()
        s.tileIDs.wall = 100
        s.tileIDs.builtSlab = 50
        return s
    }

    @Test("a 1×1 slab paints the built-concrete tile + owner; no structure object is created")
    func slab1x1() {
        var s = state()
        let packed = UInt16(20 * 64 + 20)
        s.placeSlab(.slab1x1, houseID: 2, at: packed)
        #expect(s.map[Int(packed)].groundTileID == s.tileIDs.builtSlab)
        #expect(s.map[Int(packed)].houseID == 2)
        #expect(!s.structures.contains { $0.o.flags.contains(.used) })  // not a persistent structure
    }

    @Test("a 2×2 slab paints all four footprint tiles")
    func slab2x2() {
        var s = state()
        let packed = 10 * 64 + 10
        s.placeSlab(.slab2x2, houseID: 1, at: UInt16(packed))
        for off in [ 0, 1, 64, 65 ] {  // the 2×2 footprint
            #expect(s.map[packed + off].groundTileID == s.tileIDs.builtSlab)
        }
    }

    @Test("an isolated wall is the base WALLS tile; two adjacent walls connect (both update)")
    func wallConnect() {
        var s = state()
        let a = UInt16(15 * 64 + 40)  // (40,15)
        s.placeWall(houseID: 0, at: a)
        // No neighbours yet → wallConnectTable[0] = 0 → base tile wall+1.
        #expect(s.map[Int(a)].groundTileID == s.tileIDs.wall + 1)

        // Place the eastern neighbour: it connects to A (W neighbour), and recursively re-connects A.
        let b = a + 1  // (41,15)
        s.placeWall(houseID: 0, at: b)
        // Each now has exactly one wall neighbour → wallConnectTable[bit] = 1 → wall + 2.
        #expect(s.map[Int(b)].groundTileID == s.tileIDs.wall + 2)
        #expect(s.map[Int(a)].groundTileID == s.tileIDs.wall + 2)  // A was re-connected (recurse)
        #expect(s.map[Int(a)].houseID == 0 && s.map[Int(b)].houseID == 0)
    }

    @Test("scenario [STRUCTURES] GEN/ID lines place slabs + walls into the map")
    func scenarioLoad() {
        var s = state()
        s.tileIDs.wall = 100; s.tileIDs.builtSlab = 50
        // loadStructure is exercised via loadScenario in the golden tests; here drive the placement
        // directly to confirm a wall + a slab end up on the map and no structure slot is consumed.
        s.placeWall(houseID: 0, at: UInt16(30 * 64 + 30))
        s.placeSlab(.slab1x1, houseID: 0, at: UInt16(30 * 64 + 32))
        #expect(s.map[30 * 64 + 30].groundTileID > s.tileIDs.wall)  // a wall tile
        #expect(s.map[30 * 64 + 32].groundTileID == s.tileIDs.builtSlab)
        #expect(s.structureFindArray.isEmpty)  // none entered the find array
    }
}
