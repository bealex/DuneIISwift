import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Cps")
struct CpsTests {
    @Test("uncompressed image round trip")
    func uncompressed() throws {
        let pixels = [UInt8](repeating: 0x42, count: 64_000)
        var data = Data()
        let fileSize = UInt16(10 + pixels.count - 2)
        data.append(uint16LE: fileSize)
        data.append(uint16LE: 0x0000) // uncompressed
        data.append(uint32LE: 64_000)
        data.append(uint16LE: 0)
        data.append(contentsOf: pixels)

        let image = try Formats.Cps.decode(data)
        #expect(image.compression == .none)
        #expect(image.palette == nil)
        #expect(image.pixels.count == 64_000)
        #expect(image.pixels.allSatisfy { $0 == 0x42 })
    }

    @Test("Format80 compressed image decodes to 64000 pixels")
    func format80Compressed() throws {
        // Build a Format80 stream that produces 64000 × 0x7F: long fill (0xFE) once, then exit.
        var payload = Data()
        payload.append(0xFE) // long fill
        payload.append(uint16LE: 64_000)
        payload.append(0x7F)
        payload.append(0x80) // exit

        var data = Data()
        data.append(uint16LE: UInt16(truncatingIfNeeded: 10 + payload.count - 2))
        data.append(uint16LE: 0x0004) // format80
        data.append(uint32LE: 64_000)
        data.append(uint16LE: 0)
        data.append(payload)

        let image = try Formats.Cps.decode(data)
        #expect(image.compression == .format80)
        #expect(image.pixels.count == 64_000)
        #expect(image.pixels.allSatisfy { $0 == 0x7F })
    }

    @Test("embedded palette is decoded and available on the image")
    func embeddedPalette() throws {
        var paletteBytes = Data(count: 48)
        paletteBytes[0] = 10; paletteBytes[1] = 20; paletteBytes[2] = 30

        let pixels = [UInt8](repeating: 1, count: 64_000)
        var data = Data()
        let totalMinus2 = 10 + paletteBytes.count + pixels.count - 2
        data.append(uint16LE: UInt16(totalMinus2))
        data.append(uint16LE: 0x0000)
        data.append(uint32LE: 64_000)
        data.append(uint16LE: UInt16(paletteBytes.count))
        data.append(paletteBytes)
        data.append(contentsOf: pixels)

        let image = try Formats.Cps.decode(data)
        #expect(image.palette != nil)
        #expect(image.palette?.colors[0].r6 == 10)
    }

    @Test("unsupported compression tag is rejected")
    func badCompression() {
        var data = Data()
        data.append(uint16LE: 100)
        data.append(uint16LE: 0x1234)
        data.append(uint32LE: 64_000)
        data.append(uint16LE: 0)
        data.append(Data(count: 64_000))
        #expect(throws: Formats.Cps.DecodeError.self) {
            _ = try Formats.Cps.decode(data)
        }
    }

    @Test("real MAPMACH.CPS from DUNE.PAK (if present) decodes to 64000 pixels")
    func realMapmach() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let cps = archive.body(named: "MAPMACH.CPS") else { return }
        let image = try Formats.Cps.decode(cps)
        #expect(image.pixels.count == 64_000)
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
