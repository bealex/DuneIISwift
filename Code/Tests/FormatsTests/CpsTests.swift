import Foundation
import Testing

@testable import DuneIIFormats

@Suite("Cps")
struct CpsTests {
    @Test("Format80 (type 4) body decodes to pixels")
    func format80Body() throws {
        let data = Data([
            0x00, 0x00,  // file size (ignored)
            0x04, 0x00,  // compression type = 4 (Format80)
            0x40, 0x01, 0x00, 0x00,  // uncompressed size (ignored on the type-4 path)
            0x00, 0x00,  // palette size = 0
            0xFE, 0x40, 0x01, 0xAA, 0x80,  // Format80: fill 320 bytes with 0xAA, then end
        ])
        let image = try Cps.decode(data)
        #expect(image.width == 320)
        #expect(image.height == 1)
        #expect(image.pixels.count == 320)
        #expect(image.pixels.allSatisfy { $0 == 0xAA })
        #expect(image.palette == nil)
    }

    @Test("raw (type 0) body is copied verbatim")
    func rawBody() throws {
        let data = Data([
            0x00, 0x00,  // file size
            0x00, 0x00,  // compression type = 0 (raw)
            0x04, 0x00, 0x00, 0x00,  // uncompressed size = 4
            0x00, 0x00,  // palette size = 0
            0x11, 0x22, 0x33, 0x44,  // raw image
        ])
        let image = try Cps.decode(data)
        #expect(image.pixels == [ 0x11, 0x22, 0x33, 0x44 ])
    }

    @Test("real install CPS decodes to a 320-wide image")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: ".CPS") else { return }

        let image = try Cps.decode(bytes)
        #expect(image.width == 320)
        #expect(image.pixels.count == image.width * image.height)
    }
}
