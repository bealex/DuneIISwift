import DuneIIFormats
import Testing

@testable import DuneIIRenderer

/// `ShimmerEffect` — the sandworm `DRAWSPRITE_FLAG_BLUR` realized as a CoreGraphics terrain displacement.
/// The pure `patchRGBA` is tested without a GPU: within the worm mask each pixel samples the terrain
/// `offset` columns to its right; outside the mask it is transparent.
@Suite("Shimmer effect")
struct ShimmerEffectTests {
    /// A 64-entry greyscale palette so a sampled index is recoverable from the output colour.
    private var palette: Palette {
        Palette(colors: (0 ..< 64).map { Palette.Color(red: UInt8($0), green: 0, blue: 0) })
    }

    @Test("the blur offsets are the gui.c:935 cycle")
    func offsets() {
        #expect(ShimmerEffect.blurOffsets == [ 1, 3, 2, 5, 4, 3, 2, 1 ])
    }

    @Test("within the mask each pixel samples terrain offset-columns to the right; outside is transparent")
    func displacement() throws {
        // Terrain: 20×4, each column's index == its x (so a horizontal shift is visible in the colour).
        let tw = 20, th = 4
        let terrain = (0 ..< tw * th).map { UInt8($0 % tw) }
        // A 4×2 worm at (left 5, top 1), fully opaque except the top-left pixel (to test transparency).
        let ww = 4, wh = 2, left = 5, top = 1, offset = 3
        var mask = [UInt8](repeating: 1, count: ww * wh)
        mask[0] = 0
        let pal = palette

        let rgba = try #require(
            ShimmerEffect.patchRGBA(
                terrain: terrain,
                terrainWidth: tw,
                terrainHeight: th,
                left: left,
                top: top,
                mask: mask,
                wormWidth: ww,
                wormHeight: wh,
                offset: offset,
                palette: pal
            )
        )
        #expect(rgba.count == ww * wh * 4)

        func px(_ x: Int, _ y: Int) -> (r: UInt8, a: UInt8) { let o = (y * ww + x) * 4; return (rgba[o], rgba[o + 3]) }

        // The masked-out top-left pixel is transparent.
        #expect(px(0, 0).a == 0)
        // Every other pixel samples terrain[left + x + offset] = index (5 + x + 3) = 8 + x, fully opaque.
        for y in 0 ..< wh {
            for x in 0 ..< ww where !(x == 0 && y == 0) {
                #expect(px(x, y).a == 255)
                #expect(px(x, y).r == pal.rgba8(left + x + offset).red)  // the horizontal displacement
            }
        }
        // The displacement is a real shift: adjacent output columns differ (terrain isn't uniform here).
        #expect(px(1, 0).r != px(2, 0).r)
    }

    @Test("fog: a worm pixel is transparent when its displaced sample falls on veiled terrain")
    func fogSuppression() throws {
        // Terrain 20×4, index == x. Worm 4×2 at left 5, offset 3 → pixel x samples column (5+x+3)=8+x.
        let tw = 20, th = 4, ww = 4, wh = 2, left = 5, top = 1, offset = 3
        let terrain = (0 ..< tw * th).map { UInt8($0 % tw) }
        let mask = [UInt8](repeating: 1, count: ww * wh)
        let pal = palette
        // Mark columns ≥ 10 as veiled (fog to the right). Samples for x=2,3 are columns 10,11 → veiled.
        let rgba = try #require(
            ShimmerEffect.patchRGBA(
                terrain: terrain,
                terrainWidth: tw,
                terrainHeight: th,
                left: left,
                top: top,
                mask: mask,
                wormWidth: ww,
                wormHeight: wh,
                offset: offset,
                palette: pal,
                veiled: { px, _ in px >= 10 }
            )
        )

        func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * ww + x) * 4 + 3] }

        for y in 0 ..< wh {
            #expect(alpha(0, y) == 255)  // disp 5 / sample 8  — revealed
            #expect(alpha(1, y) == 255)  // disp 6 / sample 9  — revealed
            #expect(alpha(2, y) == 0)  // disp 7 / sample 10 — sample veiled ⇒ no fog dragged in
            #expect(alpha(3, y) == 0)  // disp 8 / sample 11 — sample veiled
        }
    }
}
