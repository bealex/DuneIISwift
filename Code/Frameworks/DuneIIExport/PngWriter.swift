import CoreGraphics
import DuneIIFormats
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes 8-bit palette-indexed pixels to PNG, colorized through a `Palette`, using ImageIO /
/// CoreGraphics. For verifying that decoded sprites/images/tiles convert correctly — not part of the
/// engine's runtime path.
public enum PngWriter {
    public enum WriteError: Error {
        case invalidDimensions
        case encodeFailed
    }

    /// Encode `indices` (row-major 8-bit palette indices) to PNG data. `transparentIndex` (e.g. 0 for
    /// sprites) is written fully transparent; pass nil for an opaque image.
    public static func encode(
        indices: [UInt8],
        width: Int,
        height: Int,
        palette: Palette,
        transparentIndex: Int? = nil
    ) throws -> Data {
        guard width > 0, height > 0, indices.count >= width * height else { throw WriteError.invalidDimensions }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0 ..< (width * height) {
            let index = Int(indices[pixel])
            if let transparentIndex, index == transparentIndex { continue }   // leave (0,0,0,0)

            let color = palette.rgba8(index)
            let offset = pixel * 4
            rgba[offset] = color.red
            rgba[offset + 1] = color.green
            rgba[offset + 2] = color.blue
            rgba[offset + 3] = color.alpha
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard
            let provider = CGDataProvider(data: Data(rgba) as CFData),
            let image = CGImage(
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
        else { throw WriteError.encodeFailed }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.png.identifier as CFString, 1, nil
            )
        else { throw WriteError.encodeFailed }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.encodeFailed }

        return output as Data
    }

    public static func write(
        indices: [UInt8],
        width: Int,
        height: Int,
        palette: Palette,
        transparentIndex: Int? = nil,
        to url: URL
    ) throws {
        let data = try encode(
            indices: indices, width: width, height: height, palette: palette, transparentIndex: transparentIndex
        )
        try data.write(to: url)
    }

    /// Encode an already-rendered `CGImage` (e.g. a `SpriteKitRenderer.snapshot`) to PNG data.
    public static func encode(image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { throw WriteError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.encodeFailed }
        return output as Data
    }

    /// Write an already-rendered `CGImage` to `url` as PNG.
    public static func write(image: CGImage, to url: URL) throws {
        try encode(image: image).write(to: url)
    }
}
