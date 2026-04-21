import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Icn")
struct IcnTests {
    @Test("real ICON.ICN parses into 16×16 tiles with a valid palette table")
    func realIconIcn() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let icn = archive.body(named: "ICON.ICN") else { return }
        let tiles = try Formats.Icn.decode(icn)
        #expect(tiles.tileWidth == 16)
        #expect(tiles.tileHeight == 16)
        #expect(tiles.rpal.count % 16 == 0)
        #expect(tiles.tileCount == tiles.rtbl.count)
        #expect(tiles.tileCount > 0)
        let pixels = tiles.pixels(forTile: 0)
        #expect(pixels.count == 256)
    }

    @Test("non-FORM file is rejected")
    func notForm() {
        let data = Data("NOTAFORM".utf8)
        #expect(throws: Formats.Icn.DecodeError.self) {
            _ = try Formats.Icn.decode(data)
        }
    }

    @Test("synthetic 16×16 ICN: one tile, flat palette, upper/lower nibble split")
    func synthetic() throws {
        // Tile 0 is 128 bytes of packed 4-bit pixels where every byte is 0x12.
        // Upper nibble is the LEFT pixel (1), lower nibble is the RIGHT (2).
        let tileByteSize = 128
        let tilePacked = [UInt8](repeating: 0x12, count: tileByteSize)

        // SSET body, uncompressed: tag=0, pad=0, u32 size, u16 paletteSize=0, payload.
        var sset = Data()
        sset.append(0x00) // compression tag: uncompressed
        sset.append(0x00) // pad
        sset.append(uint32LE: UInt32(tilePacked.count))
        sset.append(uint16LE: 0)
        sset.append(contentsOf: tilePacked)

        // SINF: widthSize=2, heightSize=2, tileCountLo=1, tileCountHi=0.
        let sinf = Data([2, 2, 1, 0])
        // RTBL: tile 0 uses palette 0.
        let rtbl = Data([0])
        // RPAL: two 16-byte sub-palettes. Palette 0 maps nibble 1 → index 10,
        // nibble 2 → index 20.
        var rpal = Data(count: 16)
        rpal[1] = 10
        rpal[2] = 20

        let form = buildForm(tag: "ICON", chunks: [
            ("SINF", sinf),
            ("SSET", sset),
            ("RTBL", rtbl),
            ("RPAL", rpal)
        ])

        let tiles = try Formats.Icn.decode(form)
        #expect(tiles.tileWidth == 16)
        #expect(tiles.tileHeight == 16)
        #expect(tiles.tileCount == 1)
        let pixels = tiles.pixels(forTile: 0)
        #expect(pixels.count == 256)
        // For every byte 0x12, left = nibble 1 → 10, right = nibble 2 → 20.
        #expect(pixels[0] == 10)
        #expect(pixels[1] == 20)
        #expect(pixels.allSatisfy { $0 == 10 || $0 == 20 })
    }
}

// Small IFF builder for tests.
private func buildForm(tag: String, chunks: [(String, Data)]) -> Data {
    var body = Data()
    body.append(contentsOf: Array(tag.utf8))
    for (chunkTag, chunkData) in chunks {
        body.append(contentsOf: Array(chunkTag.utf8))
        body.append(uint32BE: UInt32(chunkData.count))
        body.append(chunkData)
        if chunkData.count % 2 != 0 { body.append(0) }
    }
    var out = Data("FORM".utf8)
    out.append(uint32BE: UInt32(body.count))
    out.append(body)
    return out
}

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func append(uint32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
    mutating func append(uint32BE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
