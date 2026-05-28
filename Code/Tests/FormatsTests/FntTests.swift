import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Fnt")
struct FntTests {
    // One glyph: width 2, 1 bitmap row, pixels [1, 2] (byte 0x21: low nibble 1 = left, high nibble 2 = right).
    static let synthetic = Data([
        0x00, 0x00,             // size word (ignored)
        0x00, 0x05,             // magic
        0x0E, 0x00,             // info block @ 14
        0x14, 0x00,             // data-pointer table @ 20
        0x16, 0x00,             // width table @ 22
        0x17, 0x00,             // (count base) 23 -> count = 23 - 22 = 1
        0x18, 0x00,             // line table @ 24
        0x00, 0x00, 0x00, 0x00, 0x02, 0x02, // info block (14..19): height @18 = 2, maxWidth @19 = 2
        0x1E, 0x00,             // data table[0] = glyph bitmap @ 30
        0x02,                   // width table[0] = 2
        0x00,                   // gap (byte 23)
        0x00, 0x01,             // line table[0]: unusedLines 0, usedLines 1
        0x00, 0x00, 0x00, 0x00, // padding (26..29)
        0x21,                   // glyph bitmap (byte 30)
    ])

    @Test("decodes the font header and a 4-bit packed glyph")
    func glyph() throws {
        let font = try Fnt.Font(FntTests.synthetic)
        #expect(font.height == 2)
        #expect(font.maxWidth == 2)
        #expect(font.glyphs.count == 1)
        #expect(font.glyph(0) == Fnt.Glyph(width: 2, topRows: 0, bitmapRows: 1, pixels: [ 1, 2 ]))
    }

    @Test("invalid magic throws")
    func invalidMagic() {
        #expect(throws: Fnt.DecodeError.invalidMagic) {
            _ = try Fnt.Font(Data(count: 16))
        }
    }

    @Test("real install FNT decodes")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: ".FNT") else { return }

        let font = try Fnt.Font(bytes)
        #expect(font.height > 0)
        #expect(!font.glyphs.isEmpty)
        for glyph in font.glyphs {
            #expect(glyph.pixels.count == glyph.width * glyph.bitmapRows)
        }
    }
}
