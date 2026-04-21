import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.TileMap")
struct SaveTileMapTests {
    @Test("record size is 6 bytes (u16 index + 4 packed tile bytes)")
    func recordSizeIs6() {
        #expect(Formats.Save.TileMap.recordSize == 6)
    }

    // MARK: Synthetic

    @Test("pinned single-tile body decodes every packed field")
    func pinnedSingleTile() throws {
        // groundTileID = 300 = 0x12C: low byte 0x2C, high bit (bit 8) set.
        // So b[0] = 0x2C, b[1] low bit = 1.
        // overlayTileID = 42 = 0x2A → stored in b[1] >> 1, so b[1] high 7 bits = 0x2A
        //   → b[1] = 0x01 | (0x2A << 1) = 0x01 | 0x54 = 0x55.
        // houseID = 3, isUnveiled, hasStructure → b[2] = 0x03 | 0x08 | 0x20 = 0x2B.
        // tileIndex = 12 → b[3] = 0x0C.
        var body = Data()
        body.append(uint16LE: 0x0123) // cellIndex: y=4 (0x123/64=4), x=35 — not strictly verified here
        body.append(0x2C) // b[0]
        body.append(0x55) // b[1]
        body.append(0x2B) // b[2]
        body.append(0x0C) // b[3]

        #expect(body.count == 6)
        let map = try Formats.Save.TileMap.decode(body)
        #expect(map.entries.count == 1)

        let e = map.entries[0]
        #expect(e.cellIndex == 0x0123)
        #expect(e.tile.groundTileID == 300)
        #expect(e.tile.overlayTileID == 42)
        #expect(e.tile.houseID == 3)
        #expect(e.tile.isUnveiled)
        #expect(!e.tile.hasUnit)
        #expect(e.tile.hasStructure)
        #expect(!e.tile.hasAnimation)
        #expect(!e.tile.hasExplosion)
        #expect(e.tile.tileIndex == 12)
    }

    @Test("9-bit groundTileID spans bytes 0 and 1 correctly")
    func groundTileIDSpansBytes() throws {
        // groundTileID = 0x1FF = 511 (maximum 9-bit value).
        // b[0] = 0xFF, b[1] bit 0 = 1, rest of b[1] = 0 → b[1] = 0x01.
        var body = Data()
        body.append(uint16LE: 0)
        body.append(0xFF) // b[0]
        body.append(0x01) // b[1] — bit 0 set, overlay = 0
        body.append(0x00) // b[2]
        body.append(0x00) // b[3]
        let map = try Formats.Save.TileMap.decode(body)
        #expect(map.entries[0].tile.groundTileID == 0x1FF)
        #expect(map.entries[0].tile.overlayTileID == 0)
    }

    @Test("overlayTileID occupies the upper 7 bits of byte 1")
    func overlayTileSpansCorrectBits() throws {
        // overlay = 0x7F (max 7-bit); groundTileID high bit clear.
        var body = Data()
        body.append(uint16LE: 0)
        body.append(0x00)       // b[0]
        body.append(0xFE)       // b[1] = 0x7F << 1
        body.append(0x00)
        body.append(0x00)
        let map = try Formats.Save.TileMap.decode(body)
        #expect(map.entries[0].tile.overlayTileID == 0x7F)
        #expect(map.entries[0].tile.groundTileID == 0)
    }

    @Test("all boolean flag bits decode independently")
    func allFlagBits() throws {
        // b[2] = 0xF8: houseID=0, isUnveiled, hasUnit, hasStructure, hasAnimation, hasExplosion all set
        var body = Data()
        body.append(uint16LE: 0)
        body.append(0x00); body.append(0x00); body.append(0xF8); body.append(0x00)
        let t = try Formats.Save.TileMap.decode(body).entries[0].tile
        #expect(t.houseID == 0)
        #expect(t.isUnveiled)
        #expect(t.hasUnit)
        #expect(t.hasStructure)
        #expect(t.hasAnimation)
        #expect(t.hasExplosion)
    }

    // MARK: Failure modes

    @Test("misaligned body rejected")
    func misalignedBody() {
        let body = Data(count: 6 + 3)
        #expect(throws: Formats.Save.TileMap.DecodeError.misalignedBody(length: body.count)) {
            _ = try Formats.Save.TileMap.decode(body)
        }
    }

    @Test("cellIndex outside the 64x64 grid is rejected")
    func cellIndexOutOfRange() {
        var body = Data()
        body.append(uint16LE: 0x1000) // exactly at the cap — invalid
        body.append(Data(count: 4))
        #expect(throws: Formats.Save.TileMap.DecodeError.cellIndexOutOfRange(0x1000)) {
            _ = try Formats.Save.TileMap.decode(body)
        }
    }

    @Test("empty body decodes to zero entries (never seen in real saves but well-defined)")
    func emptyBody() throws {
        let map = try Formats.Save.TileMap.decode(Data())
        #expect(map.entries.isEmpty)
    }

    // MARK: Real data

    @Test("_SAVE001.DAT MAP chunk decodes to a plausible sparse entry set")
    func realSave001Map() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)
        guard let chunk = container.chunk(named: "MAP ") else {
            Issue.record("MAP chunk missing"); return
        }
        #expect(chunk.count % 6 == 0)
        let map = try Formats.Save.TileMap.decode(chunk)

        // A fresh mission has some scouted / occupied tiles, but not all 4096.
        #expect(!map.entries.isEmpty)
        #expect(map.entries.count <= 4096)

        // OpenDUNE writes in ascending cellIndex order. Verify.
        var prev = -1
        for entry in map.entries {
            #expect(Int(entry.cellIndex) > prev)
            prev = Int(entry.cellIndex)
            #expect(entry.cellIndex < 0x1000)
            #expect(entry.tile.groundTileID < 512)
            #expect(entry.tile.overlayTileID < 128)
            #expect(entry.tile.houseID < 8)
        }
    }
}

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
}
