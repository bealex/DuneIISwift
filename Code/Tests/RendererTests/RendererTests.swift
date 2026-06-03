import CoreGraphics
import DuneIIFormats
import DuneIIRenderer
import Foundation
import Testing

@Suite("Renderer")
struct RendererTests {
    @Test("sprite house remap shifts the 0x90...0x98 block by houseID<<4")
    func spriteRemap() {
        #expect(HouseRemap.sprite(0x90, house: .harkonnen) == 0x90)  // base house, no shift
        #expect(HouseRemap.sprite(0x90, house: .atreides) == 0xA0)  // + 0x10
        #expect(HouseRemap.sprite(0x98, house: .ordos) == 0xB8)  // + 0x20
        #expect(HouseRemap.sprite(0x99, house: .atreides) == 0x99)  // 0x99 is outside 0x90...0x98
        #expect(HouseRemap.sprite(0x10, house: .atreides) == 0x10)  // not a house color
    }

    @Test("tile house remap shifts the whole 0x90...0x9F block")
    func tileRemap() {
        #expect(HouseRemap.tile(0x9F, house: .harkonnen) == 0x9F)
        #expect(HouseRemap.tile(0x9F, house: .atreides) == 0xAF)  // whole high-nibble-9 block
        #expect(HouseRemap.tile(0x8F, house: .atreides) == 0x8F)  // not a house color
    }

    @Test("indexed image is the right size and applies the remap before palette lookup")
    func image() throws {
        var bytes = [ UInt8 ](repeating: 0, count: 768)
        bytes[0xA0 * 3] = 63  // palette index 0xA0 = red
        let palette = try Palette(Data(bytes))
        let indices: [UInt8] = [ 0x90, 0x90, 0x90, 0x90 ]  // house-color block

        let image = try #require(
            IndexedImage.cgImage(
                indices: indices,
                width: 2,
                height: 2,
                palette: palette,
                remap: { HouseRemap.sprite($0, house: .atreides) }  // 0x90 -> 0xA0 (red)
            )
        )
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    @Test("indexed image rejects mismatched dimensions")
    func invalid() throws {
        let palette = try Palette(Data(count: 768))
        #expect(IndexedImage.cgImage(indices: [ 0, 1 ], width: 4, height: 4, palette: palette) == nil)
    }

    @Test("palette animation shifts the wind-trap index toward its target each 5 ticks")
    func paletteAnimation() throws {
        var bytes = [ UInt8 ](repeating: 0, count: 768)
        bytes[10 * 3] = 20; bytes[10 * 3 + 1] = 20; bytes[10 * 3 + 2] = 63  // entry 10 = blue
        bytes[223 * 3] = 10; bytes[223 * 3 + 1] = 10; bytes[223 * 3 + 2] = 10  // wind-trap entry, mid
        let base = try Palette(bytes: bytes)

        // tick 0 and 4: not yet a multiple of 5, unchanged.
        #expect(
            PaletteAnimator.animatedPalette(base: base, tick: 0).colors[223]
                == Palette.Color(red: 10, green: 10, blue: 10)
        )
        #expect(
            PaletteAnimator.animatedPalette(base: base, tick: 4).colors[223]
                == Palette.Color(red: 10, green: 10, blue: 10)
        )
        // tick 5: one step toward entry 12 (black) -> (9,9,9).
        #expect(
            PaletteAnimator.animatedPalette(base: base, tick: 5).colors[223] == Palette.Color(red: 9, green: 9, blue: 9)
        )
    }

    @Test("seedAnimatedColours replaces the magenta windtrap placeholder with its cycle reference (#4)")
    func paletteSeed() throws {
        var bytes = [ UInt8 ](repeating: 0, count: 768)
        bytes[12 * 3] = 9; bytes[12 * 3 + 1] = 9; bytes[12 * 3 + 2] = 9  // windtrap reference (entry 12)
        bytes[15 * 3] = 30; bytes[15 * 3 + 1] = 30; bytes[15 * 3 + 2] = 30  // selection/repair reference
        bytes[223 * 3] = 63; bytes[223 * 3 + 2] = 63  // entry 223 = magenta placeholder
        bytes[255 * 3] = 63; bytes[255 * 3 + 2] = 63
        let base = try Palette(bytes: bytes)

        // Raw: the windtrap light index is the magenta placeholder (the "purple start" bug).
        #expect(base.colors[223] == Palette.Color(red: 63, green: 0, blue: 63))

        var seeded = base.colors
        PaletteAnimator.seedAnimatedColours(&seeded)
        #expect(seeded[223] == base.colors[12])  // windtrap light seeded to entry 12, not magenta
        #expect(seeded[255] == base.colors[15])
        #expect(seeded[239] == base.colors[15])
    }

    @Test("incremental stepTick reproduces animatedPalette exactly")
    func paletteIncremental() throws {
        var bytes = [ UInt8 ](repeating: 0, count: 768)
        for i in 0 ..< 256 {  // distinct-ish entries so cycling moves
            bytes[i * 3] = UInt8(i % 64)
            bytes[i * 3 + 1] = UInt8((i * 2) % 64)
            bytes[i * 3 + 2] = UInt8((i * 3) % 64)
        }
        let base = try Palette(bytes: bytes)

        // Stepping 1...T tick-by-tick must equal the from-scratch replay at every checkpoint.
        var colors = base.colors
        var state = PaletteAnimator.CycleState()
        var tick = 0
        for target in [ 1, 3, 5, 6, 9, 15, 59, 60, 61, 120, 300 ] {
            while tick < target {
                tick += 1
                PaletteAnimator.stepTick(&colors, tick: tick, state: &state)
            }
            #expect(
                colors == PaletteAnimator.animatedPalette(base: base, tick: target).colors,
                "incremental palette diverged from replay at tick \(target)"
            )
        }

        // The change flag: a non-cycling tick reports no change; a wind tick (×5) moves index 223.
        var c = base.colors
        var s = PaletteAnimator.CycleState()
        #expect(PaletteAnimator.stepTick(&c, tick: 4, state: &s) == false)
        #expect(PaletteAnimator.stepTick(&c, tick: 5, state: &s) == true)
    }

    @Test("sprite catalog groups unit SHP frames with valid ranges")
    func catalog() {
        let units2 = SpriteCatalog.groups(inShp: "UNITS2.SHP")
        #expect(!units2.isEmpty)
        #expect(
            units2.contains {
                $0.unit == "Combat Tank" && $0.part == "turret" && $0.firstFrame == 5 && $0.frameCount == 5
            }
        )
        #expect(SpriteCatalog.unitGroups.allSatisfy { $0.firstFrame >= 0 && $0.frameCount > 0 })
    }

    @Test("structure catalog maps icon groups to their tile layouts")
    func structureLayout() {
        func layout(_ group: Int) -> (Int, Int)? {
            StructureCatalog.layout(iconGroup: group).map { ($0.width, $0.height) }
        }
        #expect(layout(19).map { $0 == (2, 2) } == true)  // Windtrap
        #expect(layout(11).map { $0 == (3, 3) } == true)  // Palace
        #expect(layout(21).map { $0 == (3, 2) } == true)  // Refinery
        #expect(layout(23).map { $0 == (1, 1) } == true)  // Gun Turret
        #expect(layout(9) == nil)  // Landscape (not a structure)
        #expect(layout(8) == nil)  // Concrete Slab (ambiguous)
    }
}

private extension Palette {
    init(bytes: [UInt8]) throws { try self.init(Data(bytes)) }
}
