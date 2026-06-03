import CoreGraphics
import DuneIIFormats
import Foundation

/// The sandworm "shimmer" (`DRAWSPRITE_FLAG_BLUR`, `gui/gui.c:1289`), realized as a CoreGraphics effect.
///
/// OpenDUNE draws the worm sprite, but for every *opaque* sprite pixel it writes `*buf = buf[blurOffset]`
/// — i.e. inside the worm's silhouette the terrain underneath is replaced by the pixel a few columns to its
/// right, so the worm shows only as a horizontal displacement of the sand (an animated heat-haze; the
/// offset cycles `blurOffsets[(i)%8]` each frame). The pure indexed compositor can't do this (it caches
/// terrain and sprites as separate textures), so we compute the displaced patch here, over the colorized
/// terrain, and the renderer lays it on top as one node. This is the Quartz/CoreGraphics realization of the
/// blur — a `CGImage` per worm per frame (worms are few).
public enum ShimmerEffect {
    /// The per-frame horizontal displacement, cycling each frame (`blurOffsets`, `gui.c:935`).
    public static let blurOffsets = [ 1, 3, 2, 5, 4, 3, 2, 1 ]

    /// Build the displaced patch for one worm: a `wormWidth × wormHeight` RGBA `CGImage` that shows, inside
    /// the worm's silhouette (`mask` pixels ≠ 0), the colorized terrain sampled `offset` columns to the
    /// **right** of each pixel (`buf[blurOffset]`); fully transparent outside the silhouette (so the real
    /// terrain node shows through). Sampling the static colorized terrain (worms cross open sand) — close
    /// enough to the per-pixel original without reading the live framebuffer.
    ///
    /// - Parameters:
    ///   - terrain: the full-map indexed ground buffer (`terrainWidth × terrainHeight`, row-major, y-down).
    ///   - left/top: the worm silhouette's top-left in terrain image space.
    ///   - mask: the worm sprite's indexed pixels (`wormWidth × wormHeight`); 0 = transparent (no displace).
    ///   - offset: the horizontal displacement (a `blurOffsets` value).
    ///   - palette: the (cycled) palette to colorize the sampled terrain index.
    public static func patch(
        terrain: [UInt8],
        terrainWidth: Int,
        terrainHeight: Int,
        left: Int,
        top: Int,
        mask: [UInt8],
        wormWidth: Int,
        wormHeight: Int,
        offset: Int,
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
                wormWidth: wormWidth,
                wormHeight: wormHeight,
                offset: offset,
                palette: palette,
                veiled: veiled
            )
        else { return nil }
        return rgbaImage(rgba, width: wormWidth, height: wormHeight)
    }

    /// The patch's raw RGBA buffer (`wormWidth · wormHeight · 4`, premultipliedLast). Pure + GPU-free, so the
    /// displacement is directly testable. `nil` on degenerate input. See `patch`.
    /// - Parameter veiled: when non-nil (fog of war shown), `veiled(px, py)` reports whether the terrain pixel
    ///   `(px, py)` is under fog. A worm pixel is left transparent when either its own display position or its
    ///   displaced source sample is veiled — so the shimmer never pulls the dithered fog edge into the worm
    ///   silhouette at a boundary, and a worm sitting in the fog shows nothing (it's hidden, like other units).
    public static func patchRGBA(
        terrain: [UInt8],
        terrainWidth: Int,
        terrainHeight: Int,
        left: Int,
        top: Int,
        mask: [UInt8],
        wormWidth: Int,
        wormHeight: Int,
        offset: Int,
        palette: Palette,
        veiled: ((Int, Int) -> Bool)? = nil
    ) -> [UInt8]? {
        guard
            wormWidth > 0,
            wormHeight > 0,
            mask.count >= wormWidth * wormHeight,
            terrain.count >= terrainWidth * terrainHeight
        else { return nil }

        var rgba = [ UInt8 ](repeating: 0, count: wormWidth * wormHeight * 4)  // transparent by default
        for y in 0 ..< wormHeight {
            let ty = top + y
            if ty < 0 || ty >= terrainHeight { continue }
            for x in 0 ..< wormWidth where mask[y * wormWidth + x] != 0 {
                let dispX = left + x  // where this worm pixel is shown
                let tx = left + x + offset  // `buf[blurOffset]`: the pixel to the right
                if tx < 0 || tx >= terrainWidth { continue }
                // Fog: don't shimmer over or pull in veiled terrain.
                if let veiled, (dispX >= 0 && dispX < terrainWidth && veiled(dispX, ty)) || veiled(tx, ty) { continue }
                let colour = palette.rgba8(Int(terrain[ty * terrainWidth + tx]))
                let o = (y * wormWidth + x) * 4
                rgba[o] = colour.red; rgba[o + 1] = colour.green; rgba[o + 2] = colour.blue; rgba[o + 3] = 255
            }
        }
        return rgba
    }

    /// A `CGImage` from a row-major RGBA8 (premultipliedLast, top-left origin) buffer — the same layout the
    /// rest of the renderer's `CGImage`s use (`IndexedImage`).
    static func rgbaImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard
            width > 0,
            height > 0,
            rgba.count >= width * height * 4,
            let provider = CGDataProvider(data: Data(rgba) as CFData)
        else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
