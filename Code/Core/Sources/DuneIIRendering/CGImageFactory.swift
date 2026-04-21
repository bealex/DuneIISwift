import Foundation
import CoreGraphics
import DuneIICore
import AssetExport

/// Utilities that turn paletted pixel buffers into `CGImage`s suitable for
/// wrapping as `SKTexture`s. Mirrors `AssetExport.PalettedImage` +
/// `AssetExport.PNGWriter` but yields in-memory images instead of writing
/// PNGs to disk.
public enum CGImageFactory {
    public enum Error: Swift.Error, Sendable {
        case contextCreationFailed
    }

    /// Paletted 8-bit indices → `CGImage` with the selected transparency mode.
    public static func makeImage(
        indices: [UInt8],
        width: Int,
        height: Int,
        palette: Formats.Palette,
        mode: PaletteRenderMode = .opaque
    ) throws -> CGImage {
        precondition(indices.count == width * height, "pixel count mismatch")
        let rgba = PalettedImage.render(
            pixels: indices, width: width, height: height, palette: palette, mode: mode
        )
        return try makeRGBAImage(bytes: rgba, width: width, height: height)
    }

    /// Two-stage palette lookup: pixels are indices into a 16-byte
    /// `subPalette` (typically an SHP frame's house-mini-palette), whose
    /// entries are then 256-color indices into the main `palette`. Used
    /// for per-house unit / structure sprites — the sub-palette is the
    /// OpenDUNE `housePalette` array, and callers remap it with
    /// `Formats.Palette.applyHouseColors(_:houseID:)` before passing it
    /// here.
    public static func makeImage(
        indices: [UInt8],
        width: Int,
        height: Int,
        subPalette: [UInt8],
        palette: Formats.Palette,
        mode: PaletteRenderMode = .index0Transparent
    ) throws -> CGImage {
        precondition(indices.count == width * height, "pixel count mismatch")
        precondition(subPalette.count == 16, "sub-palette must be 16 entries")
        // Expand each pixel through the sub-palette to get a flat 256-
        // color index buffer, then reuse the standard paletted path.
        var expanded = [UInt8](repeating: 0, count: indices.count)
        for (i, p) in indices.enumerated() {
            // Non-zero pixels use the sub-palette; zero stays zero so the
            // `index0Transparent` mode still draws transparent pixels.
            if p == 0 {
                expanded[i] = 0
            } else {
                expanded[i] = subPalette[Int(p & 0x0F)]
            }
        }
        return try makeImage(
            indices: expanded, width: width, height: height,
            palette: palette, mode: mode
        )
    }

    /// Raw RGBA8 premultiplied bytes → `CGImage`.
    public static func makeRGBAImage(
        bytes: [UInt8],
        width: Int,
        height: Int
    ) throws -> CGImage {
        precondition(bytes.count == width * height * 4, "byte count mismatch")
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buffer = bytes
        guard let ctx = buffer.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: cs, bitmapInfo: info
            )
        }), let image = ctx.makeImage() else {
            throw Error.contextCreationFailed
        }
        return image
    }
}

extension Formats.Palette {
    /// Port of OpenDUNE `GUI_Widget_Viewport_GetSprite_HousePalette`
    /// (`src/gui/viewport.c:300`). Remaps the 16-byte sprite sub-palette
    /// so byte values in `[0x90, 0x98]` pick the requested house's
    /// colour band instead of Harkonnen's. House 0 (Harkonnen) is the
    /// identity — the remap is `v + (houseID << 4)` with the original
    /// value kept for bytes outside the house range.
    public static func applyHouseColors(_ subPalette: [UInt8], houseID: UInt8) -> [UInt8] {
        precondition(subPalette.count == 16, "sub-palette must be 16 entries")
        if houseID == 0 { return subPalette }
        var out = subPalette
        for i in 0..<16 {
            let v = out[i]
            if v >= 0x90 && v <= 0x98 {
                out[i] = v &+ (houseID &<< 4)
            }
        }
        return out
    }
}
