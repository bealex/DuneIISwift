import Foundation
import Testing
@testable import DuneIIWorld

/// Golden parity of the Tier-A tile-motion primitives (`Tile_Center`, `Tile_MoveByDirection`,
/// `Tile_IsOutOfMap`) against OpenDUNE, from `tilemotion-golden.jsonl`. `Tile_MoveByDirection` also
/// exercises the ported `_stepX`/`_stepY` step tables over a grid of orientation × distance.
@Suite("Tile motion golden parity")
struct TileMotionGoldenTests {
    struct Row: Decodable {
        let fn: String
        let `in`: [UInt16]?
        let orientation: Int16?
        let distance: UInt16?
        let packed: UInt16?
        let out: GoldenFixture.IntList
    }

    private func rows(_ fn: String) -> [Row] {
        GoldenFixture.decode("tilemotion-golden.jsonl", as: Row.self).filter { $0.fn == fn }
    }

    @Test("Tile_Center")
    func center() {
        let records = rows("Tile_Center")
        #expect(!records.isEmpty)
        for r in records {
            let result = Tile32(x: r.in![0], y: r.in![1]).centered
            #expect(result == Tile32(x: UInt16(r.out.values[0]), y: UInt16(r.out.values[1])))
        }
    }

    @Test("Tile_MoveByDirection over orientation × distance")
    func moveByDirection() {
        let records = rows("Tile_MoveByDirection")
        #expect(records.count == 350)
        for r in records {
            let result = Tile32.moveByDirection(
                Tile32(x: r.in![0], y: r.in![1]), orientation: r.orientation!, distance: r.distance!)
            #expect(result == Tile32(x: UInt16(r.out.values[0]), y: UInt16(r.out.values[1])),
                    "in \(r.in!) orient \(r.orientation!) dist \(r.distance!)")
        }
    }

    @Test("Tile_IsOutOfMap")
    func isOutOfMap() {
        let records = rows("Tile_IsOutOfMap")
        #expect(!records.isEmpty)
        for r in records {
            #expect(Tile32.isOutOfMap(r.packed!) == (r.out.scalar != 0), "packed \(r.packed!)")
        }
    }
}
