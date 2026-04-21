import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Shp")
struct ShpTests {
    /// Assembles a single-frame modern-format SHP.
    ///
    /// File layout (matches real DUNE.PAK entries like MOUSE.SHP):
    /// - u16 count
    /// - (count+1) u32 offsets: offset[i] is the byte position of frame i's
    ///   block (which begins 2 bytes before the real frame header). The
    ///   last entry is the EOF offset. Because `offset[0] == 4 + count*4`,
    ///   the "2 bytes before frame header" slice overlaps with the high
    ///   bytes of offset[count] — no separate skip prefix is written.
    /// - The 10-byte frame header plus payload, starting at byte
    ///   `offset[0] + 2 = 4 + count*4 + 2`.
    private static func buildModernShp(
        flags: UInt16,
        width: Int,
        height: Int,
        housePalette: [UInt8]? = nil,
        pixelStream: [UInt8]
    ) -> Data {
        let headerBlockSize = 10 + (housePalette?.count ?? 0) + pixelStream.count
        let offset0 = 8 // 2 (count) + 4 (offset[0]) + 4 (offset[1] terminator)
        let fileSize = offset0 + 2 + headerBlockSize

        var file = Data()
        file.append(uint16LE: 1)
        file.append(uint32LE: UInt32(offset0))
        file.append(uint32LE: UInt32(fileSize - 2)) // terminator (sibling semantics)
        file.append(uint16LE: flags)
        file.append(UInt8(height))
        file.append(uint16LE: UInt16(width))
        file.append(UInt8(height))
        file.append(uint16LE: 0)
        file.append(uint16LE: UInt16(pixelStream.count))
        if let housePalette { file.append(contentsOf: housePalette) }
        file.append(contentsOf: pixelStream)
        return file
    }

    @Test("single raw frame, modern format")
    func syntheticRawModern() throws {
        let width = 4, height = 2
        // Row-RLE stream: two rows of literal non-zero pixels.
        let stream: [UInt8] = [1,2,3,4, 5,6,7,8]
        let file = Self.buildModernShp(flags: 0x0002, width: width, height: height, pixelStream: stream)

        let set = try Formats.Shp.decode(file)
        #expect(set.frames.count == 1)
        let f = set.frames[0]
        #expect(f.width == width)
        #expect(f.height == height)
        #expect(f.wasFormat80Encoded == false)
        #expect(f.hasHousePalette == false)
        #expect(f.pixels == stream)
    }

    @Test("row RLE expands `00 N` runs to transparent pixels (index 0)")
    func rowRleTransparent() throws {
        // 5×1 frame. Stream: color 7, then 00 03 (3 transparent), then color 9.
        let stream: [UInt8] = [7, 0, 3, 9]
        let file = Self.buildModernShp(flags: 0x0002, width: 5, height: 1, pixelStream: stream)
        let set = try Formats.Shp.decode(file)
        #expect(set.frames[0].pixels == [7, 0, 0, 0, 9])
    }

    @Test("Format80-compressed frame round trips")
    func syntheticCompressedModern() throws {
        let width = 8, height = 1
        // RLE stream (decoded from format80) = 8 × 0x5A.
        // Format80 long fill: 0xFE 0x08 0x00 0x5A then 0x80 exit.
        let format80: [UInt8] = [0xFE, 0x08, 0x00, 0x5A, 0x80]

        let headerBlockSize = 10 + format80.count
        let offset0 = 8
        let fileSize = offset0 + 2 + headerBlockSize

        var file = Data()
        file.append(uint16LE: 1)
        file.append(uint32LE: UInt32(offset0))
        file.append(uint32LE: UInt32(fileSize - 2))
        file.append(uint16LE: 0x0000) // compressed, no palette
        file.append(UInt8(height))
        file.append(uint16LE: UInt16(width))
        file.append(UInt8(height))
        file.append(uint16LE: 0)
        file.append(uint16LE: 8) // decoded size = post-format80 stream length
        file.append(contentsOf: format80)

        let set = try Formats.Shp.decode(file)
        let f = set.frames[0]
        #expect(f.wasFormat80Encoded == true)
        #expect(f.pixels == [UInt8](repeating: 0x5A, count: 8))
    }

    @Test("house palette is captured when flag bit 0 is set")
    func housePalette() throws {
        let width = 2, height = 2
        let palette: [UInt8] = Array(0..<16)
        let stream: [UInt8] = [10, 20, 30, 40]
        let file = Self.buildModernShp(
            flags: 0x0003,
            width: width,
            height: height,
            housePalette: palette,
            pixelStream: stream
        )
        let set = try Formats.Shp.decode(file)
        let f = set.frames[0]
        #expect(f.housePalette == palette)
        #expect(f.pixels == stream)
    }

    @Test("real MOUSE.SHP parses with valid frames")
    func realMouseShp() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let shp = archive.body(named: "MOUSE.SHP") else { return }
        let set = try Formats.Shp.decode(shp)
        #expect(set.frames.count >= 1)
        for frame in set.frames {
            #expect(frame.pixels.count == frame.width * frame.height)
        }
    }

    @Test("real UNITS.SHP parses with valid frames")
    func realUnitsShp() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let shp = archive.body(named: "UNITS.SHP") else { return }
        let set = try Formats.Shp.decode(shp)
        #expect(set.frames.count >= 10)
        for frame in set.frames {
            #expect(frame.pixels.count == frame.width * frame.height)
        }
    }
}

extension Data {
    mutating fileprivate func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating fileprivate func append(uint32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
