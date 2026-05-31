import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded RGBA8 image for pixel-exact golden comparison. Backed by a tightly-packed `w*h*4` byte buffer
/// (origin top-left) so two captures of the same scene compare byte-for-byte.
struct PngImage: Equatable {
    let width: Int
    let height: Int
    /// Row-major RGBA, 4 bytes per pixel, no row padding.
    let rgba: [UInt8]

    /// Rasterize a `CGImage` into a tightly-packed RGBA8 buffer.
    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let space = CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.premultipliedLast.rawValue
            if let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w * 4, space: space, bitmapInfo: info) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        width = w
        height = h
        rgba = buffer
    }

    /// Decode a PNG file into RGBA8, or `nil` if it can't be read/decoded.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        self.init(image)
    }

    /// Encode a `CGImage` to PNG on disk (used to record a reference).
    static func write(_ image: CGImage, to url: URL) throws {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw Err.encode }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Err.encode }
        try (out as Data).write(to: url)
    }

    enum Err: Error { case encode }

    /// The number of pixels that differ from `other` by more than `tolerance` on any channel, the first such
    /// pixel (top-left scan order), and the largest single-channel delta seen. Both images must be the same
    /// size (a size mismatch reports every pixel as different).
    struct Diff: Equatable { var mismatches: Int; var first: (x: Int, y: Int)?; var maxDelta: Int
        static func == (a: Diff, b: Diff) -> Bool {
            a.mismatches == b.mismatches && a.maxDelta == b.maxDelta && a.first?.x == b.first?.x && a.first?.y == b.first?.y
        }
    }

    func diff(_ other: PngImage, tolerance: Int = 0) -> Diff {
        guard width == other.width, height == other.height else {
            return Diff(mismatches: width * height, first: (0, 0), maxDelta: 255)
        }
        var mismatches = 0
        var first: (x: Int, y: Int)?
        var maxDelta = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            var delta = 0
            for c in 0 ..< 4 { delta = max(delta, abs(Int(rgba[i + c]) - Int(other.rgba[i + c]))) }
            if delta > maxDelta { maxDelta = delta }
            if delta > tolerance {
                mismatches += 1
                if first == nil { let p = i / 4; first = (p % width, p / width) }
            }
        }
        return Diff(mismatches: mismatches, first: first, maxDelta: maxDelta)
    }
}
