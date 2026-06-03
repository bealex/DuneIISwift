import Foundation
import Testing

@testable import DuneIIFormats

@Suite("Palette")
struct PaletteTests {
    @Test("parses 256 six-bit RGB triples")
    func parse() throws {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[0] = 63; bytes[1] = 0; bytes[2] = 32  // color 0
        bytes[3] = 10  // color 1, red
        let palette = try Palette(Data(bytes))
        #expect(palette.colors.count == 256)
        #expect(palette.colors[0] == Palette.Color(red: 63, green: 0, blue: 32))
        #expect(palette.colors[1].red == 10)
    }

    @Test("6-bit to 8-bit expansion matches the original display path")
    func expansion() {
        #expect(Palette.expand6to8(0) == 0)
        #expect(Palette.expand6to8(63) == 255)
        #expect(Palette.expand6to8(32) == 130)
    }

    @Test("rgba8 expands a color and is opaque")
    func rgba8() throws {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[0] = 63; bytes[1] = 0; bytes[2] = 32
        let palette = try Palette(Data(bytes))
        let color = palette.rgba8(0)
        #expect(color.red == 255)
        #expect(color.green == 0)
        #expect(color.blue == 130)
        #expect(color.alpha == 255)
    }

    @Test("wrong size throws")
    func wrongSize() {
        #expect(throws: Palette.DecodeError.wrongSize) {
            _ = try Palette(Data(count: 100))
        }
    }

    @Test("real install IBM.PAL parses to 256 colors in range")
    func realData() throws {
        guard let bytes = TestInstall.data("IBM.PAL") else { return }

        let palette = try Palette(bytes)
        #expect(palette.colors.count == 256)
        #expect(palette.colors.allSatisfy { $0.red <= 63 && $0.green <= 63 && $0.blue <= 63 })
    }
}
