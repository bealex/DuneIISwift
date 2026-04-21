import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Palette")
struct PaletteTests {
    @Test("768-byte buffer decodes to 256 colors")
    func fullPalette() throws {
        var data = Data(count: 768)
        for i in 0..<256 {
            data[i * 3 + 0] = UInt8(i % 64)
            data[i * 3 + 1] = UInt8((i * 2) % 64)
            data[i * 3 + 2] = UInt8((i * 3) % 64)
        }
        let palette = try Formats.Palette(data: data)
        #expect(palette.colors.count == 256)
        #expect(palette.colors[0].r6 == 0)
        #expect(palette.colors[1].r6 == 1)
        #expect(palette.colors[1].g6 == 2)
        #expect(palette.colors[1].b6 == 3)
    }

    @Test("6-bit to 8-bit uses bit replication so 63 maps to 255")
    func bitReplicationScaling() throws {
        var data = Data(count: 768)
        data[0] = 63; data[1] = 63; data[2] = 63
        data[3] = 0;  data[4] = 0;  data[5] = 0
        let palette = try Formats.Palette(data: data)
        #expect(palette.colors[0].rgba8 == 0xFFFFFFFF)
        #expect(palette.colors[1].rgba8 == 0x000000FF)
    }

    @Test("wrong size is rejected")
    func wrongSize() {
        let data = Data(count: 100)
        #expect(throws: Formats.Palette.DecodeError.self) {
            _ = try Formats.Palette(data: data)
        }
    }

    @Test("channel >= 64 is rejected")
    func outOfRangeChannel() {
        var data = Data(count: 768)
        data[5] = 64
        #expect(throws: Formats.Palette.DecodeError.self) {
            _ = try Formats.Palette(data: data)
        }
    }

    @Test("partial palette zero-pads to 256 entries")
    func partial() throws {
        let data = Data([10, 20, 30, 40, 50, 60])
        let palette = try Formats.Palette.fromPartial(data)
        #expect(palette.colors[0].r6 == 10)
        #expect(palette.colors[1].b6 == 60)
        #expect(palette.colors[2].rgba8 == 0x000000FF)
    }
}
