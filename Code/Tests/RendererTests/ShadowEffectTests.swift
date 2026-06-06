import DuneIIFormats
import Testing

@testable import DuneIIRenderer

/// `ShadowMapping` (the `g_paletteMapping1` darkening LUT) + `ShadowEffect` (the winger drop shadow realized
/// as a CoreGraphics terrain darken). Both are pure, so they test without a GPU.
@Suite("Winger shadow")
struct ShadowEffectTests {
    /// A grayscale palette whose red component recovers the index (`< 64`), so a sampled / remapped index is
    /// visible in the output colour. Indices ≥ 64 clamp to gray 63 (the shadow outputs stay < 64 in tests).
    private var palette: Palette {
        Palette(colors: (0 ..< 256).map { Palette.Color(red: UInt8(min($0, 63)), green: 0, blue: 0) })
    }

    // MARK: ShadowMapping

    @Test("the LUT keeps index 0 and the fixed entries, and blends every colour ~33% toward reference 0xC")
    func mappingBlendsTowardReference() {
        // A grayscale ramp: indices 0...63 are distinct grays, 64...255 all white (gray 63). Reference 0xC is
        // gray 12, so the blend brightens colours darker than 12 and darkens brighter ones (not a pure
        // darken — it pulls toward the dark-ish reference colour, exactly like GUI_Palette_CreateMapping).
        let pal = Palette(colors: (0 ..< 256).map { Palette.Color(red: UInt8(min($0, 63)), green: UInt8(min($0, 63)), blue: UInt8(min($0, 63))) })
        let lut = ShadowMapping.table(pal)

        #expect(lut.count == 256)
        #expect(lut[0] == 0)  // GUI_Palette_CreateMapping sets colours[0] = 0
        for f in ShadowMapping.fixed { #expect(lut[f] == UInt8(f)) }  // fixed overrides kept identity

        func gray(_ i: Int) -> Int { Int(pal.colors[i].red) }
        let half = ShadowMapping.intensity / 2  // 0x2A
        // Each distinct grayscale index maps to the index whose gray is ≈ `g - (g-12)*42/128`. Indices whose
        // blend rounds to no movement (13...15) shift to the nearest *other* index (a colour can't map to
        // itself unless it's the reference), so allow ±1 around the ideal blend.
        for i in 1 ..< 64 where !ShadowMapping.fixed.contains(i) {
            let expected = i - (((i - ShadowMapping.reference) * half) >> 7)  // arithmetic shift
            #expect(abs(gray(Int(lut[i])) - expected) <= 1)
        }
        #expect(gray(Int(lut[63])) < 63)  // a bright colour is pulled darker
        #expect(gray(Int(lut[1])) > 1)  // a near-black colour is pulled up toward gray 12
    }

    @Test("a degenerate (< 256 colour) palette returns the identity table")
    func mappingIdentityFallback() {
        let lut = ShadowMapping.table(Palette(colors: (0 ..< 16).map { _ in Palette.Color(red: 0, green: 0, blue: 0) }))
        #expect(lut == (0 ... 255).map { UInt8($0) })
    }

    // MARK: ShadowEffect

    @Test("within the body silhouette each pixel darkens the terrain beneath; outside is transparent")
    func darkening() throws {
        // Terrain 20×4, each column's index == its x. A halving shadow LUT so the remap is recoverable.
        let tw = 20, th = 4
        let terrain = (0 ..< tw * th).map { UInt8($0 % tw) }
        let shadow = (0 ..< 256).map { UInt8($0 / 2) }
        // A 4×2 silhouette at (left 5, top 1), opaque except the top-left pixel (the transparency probe).
        let sw = 4, sh = 2, left = 5, top = 1
        var mask = [UInt8](repeating: 1, count: sw * sh)
        mask[0] = 0
        let pal = palette

        let rgba = try #require(
            ShadowEffect.patchRGBA(
                terrain: terrain,
                terrainWidth: tw,
                terrainHeight: th,
                left: left,
                top: top,
                mask: mask,
                spriteWidth: sw,
                spriteHeight: sh,
                shadow: shadow,
                palette: pal
            )
        )
        #expect(rgba.count == sw * sh * 4)

        func px(_ x: Int, _ y: Int) -> (r: UInt8, a: UInt8) { let o = (y * sw + x) * 4; return (rgba[o], rgba[o + 3]) }

        #expect(px(0, 0).a == 0)  // masked-out pixel is transparent
        for y in 0 ..< sh {
            for x in 0 ..< sw where !(x == 0 && y == 0) {
                let under = left + x  // terrain index directly beneath
                #expect(px(x, y).a == 255)
                #expect(px(x, y).r == pal.rgba8(Int(shadow[under])).red)  // darkened terrain, not the sprite's colour
            }
        }
    }

    @Test("fog: a shadow pixel over veiled terrain is transparent")
    func fogSuppression() throws {
        let tw = 20, th = 4, sw = 4, sh = 2, left = 5, top = 1
        let terrain = (0 ..< tw * th).map { UInt8($0 % tw) }
        let shadow = (0 ..< 256).map { UInt8($0) }
        let mask = [UInt8](repeating: 1, count: sw * sh)

        // Columns ≥ 7 are veiled → pixels x=2,3 (columns 7,8) fall on fog.
        let rgba = try #require(
            ShadowEffect.patchRGBA(
                terrain: terrain,
                terrainWidth: tw,
                terrainHeight: th,
                left: left,
                top: top,
                mask: mask,
                spriteWidth: sw,
                spriteHeight: sh,
                shadow: shadow,
                palette: palette,
                veiled: { px, _ in px >= 7 }
            )
        )

        func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * sw + x) * 4 + 3] }
        for y in 0 ..< sh {
            #expect(alpha(0, y) == 255)  // column 5 — revealed
            #expect(alpha(1, y) == 255)  // column 6 — revealed
            #expect(alpha(2, y) == 0)  // column 7 — veiled
            #expect(alpha(3, y) == 0)  // column 8 — veiled
        }
    }
}
