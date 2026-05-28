import CoreGraphics
import Foundation
import Testing
import DuneIIFormats
import DuneIIRenderer

@Suite("Renderer")
struct RendererTests {
    @Test("sprite house remap shifts the 0x90...0x98 block by houseID<<4")
    func spriteRemap() {
        #expect(HouseRemap.sprite(0x90, house: .harkonnen) == 0x90)   // base house, no shift
        #expect(HouseRemap.sprite(0x90, house: .atreides) == 0xA0)    // + 0x10
        #expect(HouseRemap.sprite(0x98, house: .ordos) == 0xB8)       // + 0x20
        #expect(HouseRemap.sprite(0x99, house: .atreides) == 0x99)    // 0x99 is outside 0x90...0x98
        #expect(HouseRemap.sprite(0x10, house: .atreides) == 0x10)    // not a house color
    }

    @Test("tile house remap shifts the whole 0x90...0x9F block")
    func tileRemap() {
        #expect(HouseRemap.tile(0x9F, house: .harkonnen) == 0x9F)
        #expect(HouseRemap.tile(0x9F, house: .atreides) == 0xAF)      // whole high-nibble-9 block
        #expect(HouseRemap.tile(0x8F, house: .atreides) == 0x8F)      // not a house color
    }

    @Test("indexed image is the right size and applies the remap before palette lookup")
    func image() throws {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[0xA0 * 3] = 63   // palette index 0xA0 = red
        let palette = try Palette(Data(bytes))
        let indices: [UInt8] = [ 0x90, 0x90, 0x90, 0x90 ]   // house-color block

        let image = try #require(IndexedImage.cgImage(
            indices: indices, width: 2, height: 2, palette: palette,
            remap: { HouseRemap.sprite($0, house: .atreides) }   // 0x90 -> 0xA0 (red)
        ))
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    @Test("indexed image rejects mismatched dimensions")
    func invalid() throws {
        let palette = try Palette(Data(count: 768))
        #expect(IndexedImage.cgImage(indices: [ 0, 1 ], width: 4, height: 4, palette: palette) == nil)
    }
}
