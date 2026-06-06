import CoreGraphics
import DuneIIFormats
import Foundation

/// A winger's drop **shadow** (`viewport.c:736` — `hasShadow` units: carryall, ornithopter, frigate),
/// realized as a CoreGraphics effect the way `ShimmerEffect` realizes the sandworm blur.
///
/// OpenDUNE draws the body silhouette a second time at `(x + 1, y + 3)` with `REMAP | BLUR` and
/// `g_paletteMapping1`; that draw (`gui.c:1303`) ignores the sprite's own colours — for every *opaque*
/// silhouette pixel it reads the **background** pixel beneath and remaps it through the darkening LUT
/// (`ShadowMapping`). So the shadow is the body's shape darkening whatever it covers. Buildings are baked
/// into the terrain tile layer (`Structure_UpdateMap`), so sampling the colorized terrain buffer — exactly
/// as the shimmer does — darkens both terrain and the building underneath an aircraft. (Ground units under
/// the shadow aren't in the terrain buffer; that minor case is omitted, like the shimmer's.)
public enum ShadowEffect {
    /// Build the shadow patch for one winger: a `spriteWidth × spriteHeight` RGBA `CGImage` showing, inside
    /// the body silhouette (`mask` pixels ≠ 0), the colorized terrain pixel directly beneath remapped through
    /// `shadow`; fully transparent outside the silhouette. See `patchRGBA`.
    public static func patch(
        terrain: [UInt8],
        terrainWidth: Int,
        terrainHeight: Int,
        left: Int,
        top: Int,
        mask: [UInt8],
        spriteWidth: Int,
        spriteHeight: Int,
        shadow: [UInt8],
        palette: Palette,
        veiled: ((Int, Int) -> Bool)? = nil
    ) -> CGImage? {
        guard
            let rgba = patchRGBA(
                terrain: terrain,
                terrainWidth: terrainWidth,
                terrainHeight: terrainHeight,
                left: left,
                top: top,
                mask: mask,
                spriteWidth: spriteWidth,
                spriteHeight: spriteHeight,
                shadow: shadow,
                palette: palette,
                veiled: veiled
            )
        else { return nil }

        return ShimmerEffect.rgbaImage(rgba, width: spriteWidth, height: spriteHeight)
    }

    /// The patch's raw RGBA buffer (`spriteWidth · spriteHeight · 4`, premultipliedLast). Pure + GPU-free, so
    /// the darkening is directly testable. For each masked pixel: `out = palette[ shadow[ terrain[under] ] ]`;
    /// unmasked pixels stay transparent. `nil` on degenerate input.
    /// - Parameter veiled: when non-nil (fog shown), a pixel over veiled terrain is left transparent (a
    ///   winger over the fog is hidden, like its body — `viewport.c` masks the air pass by `isUnveiled`).
    public static func patchRGBA(
        terrain: [UInt8],
        terrainWidth: Int,
        terrainHeight: Int,
        left: Int,
        top: Int,
        mask: [UInt8],
        spriteWidth: Int,
        spriteHeight: Int,
        shadow: [UInt8],
        palette: Palette,
        veiled: ((Int, Int) -> Bool)? = nil
    ) -> [UInt8]? {
        guard
            spriteWidth > 0,
            spriteHeight > 0,
            mask.count >= spriteWidth * spriteHeight,
            shadow.count >= 256,
            terrain.count >= terrainWidth * terrainHeight
        else { return nil }

        var rgba = [UInt8](repeating: 0, count: spriteWidth * spriteHeight * 4)  // transparent by default
        for y in 0 ..< spriteHeight {
            let ty = top + y
            if ty < 0 || ty >= terrainHeight { continue }
            for x in 0 ..< spriteWidth where mask[y * spriteWidth + x] != 0 {
                let tx = left + x
                if tx < 0 || tx >= terrainWidth { continue }
                if let veiled, veiled(tx, ty) { continue }  // don't cast a shadow over fog

                let darkened = Int(shadow[Int(terrain[ty * terrainWidth + tx])])
                let colour = palette.rgba8(darkened)
                let o = (y * spriteWidth + x) * 4
                rgba[o] = colour.red; rgba[o + 1] = colour.green; rgba[o + 2] = colour.blue; rgba[o + 3] = 255
            }
        }
        return rgba
    }
}
