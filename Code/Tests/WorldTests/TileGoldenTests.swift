import Foundation
import Testing
@testable import DuneIIWorld

/// Bit-exact parity of the tile geometry + orientation primitives against OpenDUNE, from the shared
/// golden fixture (see `GoldenFixture`).
@Suite("Tile golden parity")
struct TileGoldenTests {
    @Test("Tile_UnpackTile + round-trip pack")
    func unpack() {
        let records = GoldenFixture.records("tile-golden.jsonl", fn: "Tile_UnpackTile")
        #expect(!records.isEmpty)
        for record in records {
            let packed = record.packed!
            let tile = Tile32.unpack(packed)
            #expect(Int(tile.x) == record.out.values[0])
            #expect(Int(tile.y) == record.out.values[1])
            #expect(tile.packed == packed, "round-trip pack of \(packed)")
        }
    }

    @Test("Tile_GetDistancePacked")
    func distancePacked() {
        let records = GoldenFixture.records("tile-golden.jsonl", fn: "Tile_GetDistancePacked")
        #expect(!records.isEmpty)
        for record in records {
            let actual = Tile32.distancePacked(record.from!.uint16, record.to!.uint16)
            #expect(Int(actual) == record.out.scalar, "from \(record.from!.scalar) to \(record.to!.scalar)")
        }
    }

    @Test("Tile_GetDirectionPacked")
    func directionPacked() {
        let records = GoldenFixture.records("tile-golden.jsonl", fn: "Tile_GetDirectionPacked")
        #expect(!records.isEmpty)
        for record in records {
            let actual = Tile32.directionPacked(record.from!.uint16, record.to!.uint16)
            #expect(Int(actual) == record.out.scalar, "from \(record.from!.scalar) to \(record.to!.scalar)")
        }
    }

    @Test("Tile_GetDistance")
    func distance() {
        let records = GoldenFixture.records("tile-golden.jsonl", fn: "Tile_GetDistance")
        #expect(!records.isEmpty)
        for record in records {
            let actual = Tile32.distance(from: record.from!.tile, to: record.to!.tile)
            #expect(Int(actual) == record.out.scalar)
        }
    }

    @Test("Tile_GetDistanceRoundedUp")
    func distanceRoundedUp() {
        let records = GoldenFixture.records("tile-golden.jsonl", fn: "Tile_GetDistanceRoundedUp")
        #expect(!records.isEmpty)
        for record in records {
            let actual = Tile32.distanceRoundedUp(from: record.from!.tile, to: record.to!.tile)
            #expect(Int(actual) == record.out.scalar)
        }
    }

    @Test("Tile_GetDirection (signed)")
    func direction() {
        let records = GoldenFixture.records("tile-golden.jsonl", fn: "Tile_GetDirection")
        #expect(!records.isEmpty)
        for record in records {
            let actual = Tile32.direction(from: record.from!.tile, to: record.to!.tile)
            #expect(Int(actual) == record.out.scalar, "from \(record.from!.values) to \(record.to!.values)")
        }
    }

    @Test("Orientation_Orientation256ToOrientation8 / 16 over all 256 inputs")
    func orientation() throws {
        let to8 = try #require(GoldenFixture.records("tile-golden.jsonl", fn: "Orientation_Orientation256ToOrientation8").first)
        let to16 = try #require(GoldenFixture.records("tile-golden.jsonl", fn: "Orientation_Orientation256ToOrientation16").first)
        #expect(to8.out.values.count == 256)
        for input in 0 ..< 256 {
            #expect(Int(Orientation.to8(UInt8(input))) == to8.out.values[input], "to8(\(input))")
            #expect(Int(Orientation.to16(UInt8(input))) == to16.out.values[input], "to16(\(input))")
        }
    }
}

private extension GoldenFixture.IntList {
    /// The scalar form as a `UInt16` (packed-tile fields).
    var uint16: UInt16 { UInt16(scalar) }
    /// The `[x, y]` form as a `Tile32`.
    var tile: Tile32 { Tile32(x: UInt16(values[0]), y: UInt16(values[1])) }
}
