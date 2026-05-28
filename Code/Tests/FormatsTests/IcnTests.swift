import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Icn")
struct IcnTests {
    // Synthetic ICN: 8x8 tiles (SINF 1,1 => 4 bytes/row * 8 rows = 32 bytes/tile), one tile, raw SSET.
    static func synthetic() -> Data {
        var tile = [UInt8](repeating: 0, count: 32)
        tile[0] = 0x10   // first byte: high nibble 1 (left), low nibble 0 (right)
        // Raw image block (type 0): [type u16][size u32 LE = 32][skip u16][32-byte payload].
        var sset: [UInt8] = [ 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00 ]
        sset += tile
        let rpal = (0 ..< 16).map { UInt8(0xE0 + $0) }
        return IffBuilder.form("ICON", [
            IffBuilder.chunk("SINF", [ 1, 1, 0, 0 ]),
            IffBuilder.chunk("SSET", sset),
            IffBuilder.chunk("RTBL", [ 0 ]),
            IffBuilder.chunk("RPAL", rpal),
        ])
    }

    @Test("decodes tile geometry and the RTBL/RPAL nibble indirection")
    func tile() throws {
        let set = try Icn.TileSet(IcnTests.synthetic())
        #expect(set.tileWidth == 8)
        #expect(set.tileHeight == 8)
        #expect(set.tileCount == 1)
        let pixels = set.tile(0)
        #expect(pixels.count == 64)
        #expect(pixels[0] == 0xE1)   // high nibble 1 -> rpal[base + 1]
        #expect(pixels[1] == 0xE0)   // low nibble 0  -> rpal[base + 0]
        #expect(pixels[2] == 0xE0)   // remaining bytes are 0 -> rpal[0]
    }

    @Test("missing chunks throw")
    func missing() {
        let empty = IffBuilder.form("ICON", [])
        #expect(throws: Icn.DecodeError.missingChunk) {
            _ = try Icn.TileSet(empty)
        }
    }

    @Test("real install ICON.ICN decodes")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: "ICON.ICN") else { return }

        let set = try Icn.TileSet(bytes)
        #expect(set.tileCount > 0)
        #expect(set.tile(0).count == set.tileWidth * set.tileHeight)
    }
}
