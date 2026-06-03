import CoreGraphics
import DuneIIFormats
import Foundation

/// Turns 8-bit palette-indexed pixels into a `CGImage`, colorized through a `Palette`. This is the
/// renderer's core asset-drawing service used by the render-test app (and, later, the SpriteKit world
/// renderer). Nearest-neighbor display scaling is the consumer's job — the image is produced at native
/// pixel size, unsmoothed (`shouldInterpolate: false`).
public enum IndexedImage {
    /// Colorize `indices` (row-major) into a `CGImage`. `transparentIndex` (e.g. 0 for sprites) becomes
    /// fully transparent; `remap` transforms each index before palette lookup (house recoloring) and
    /// defaults to identity.
    public static func cgImage(
        indices: [UInt8],
        width: Int,
        height: Int,
        palette: Palette,
        transparentIndex: Int? = nil,
        remap: (UInt8) -> UInt8 = { $0 }
    ) -> CGImage? {
        guard width > 0, height > 0, indices.count >= width * height else { return nil }

        var rgba = [ UInt8 ](repeating: 0, count: width * height * 4)
        for pixel in 0 ..< (width * height) {
            let original = indices[pixel]
            if let transparentIndex, Int(original) == transparentIndex { continue }  // leave (0,0,0,0)

            let color = palette.rgba8(Int(remap(original)))
            let offset = pixel * 4
            rgba[offset] = color.red
            rgba[offset + 1] = color.green
            rgba[offset + 2] = color.blue
            rgba[offset + 3] = color.alpha
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
