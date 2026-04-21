import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import DuneIICore

/// Raw RGBA8 → PNG on disk. The caller owns palette lookup + transparency
/// choice; by this point the buffer is already premultiplied RGBA.
public enum PNGWriter {
    public static func write(rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        precondition(rgba.count == width * height * 4)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buffer = rgba
        guard let ctx = buffer.withUnsafeMutableBytes({ bufPtr -> CGContext? in
            CGContext(
                data: bufPtr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: info
            )
        }), let image = ctx.makeImage() else {
            throw AssetgenError.pngCreateFailed(url)
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw AssetgenError.pngCreateFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw AssetgenError.pngCreateFailed(url)
        }
    }
}

/// Lookup strategy: palette index 0 may be transparent (sprites/tiles) or a
/// real black (CPS full-screen backgrounds). The caller picks.
public enum PaletteRenderMode: Sendable {
    case opaque
    case index0Transparent
}

public enum PalettedImage {
    public static func render(
        pixels: [UInt8],
        width: Int,
        height: Int,
        palette: Formats.Palette,
        mode: PaletteRenderMode = .opaque
    ) -> [UInt8] {
        precondition(pixels.count == width * height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colors = palette.colors
        for (i, idx) in pixels.enumerated() {
            let base = i * 4
            if mode == .index0Transparent && idx == 0 {
                rgba[base + 3] = 0
                continue
            }
            let c = colors[Int(idx)]
            let r = (c.r6 << 2) | (c.r6 >> 4)
            let g = (c.g6 << 2) | (c.g6 >> 4)
            let b = (c.b6 << 2) | (c.b6 >> 4)
            rgba[base + 0] = r
            rgba[base + 1] = g
            rgba[base + 2] = b
            rgba[base + 3] = 0xFF
        }
        return rgba
    }
}

/// Minimal RIFF/WAV writer for unsigned 8-bit mono PCM — exactly what VOC
/// delivers. Everything is little-endian.
public enum WAVWriter {
    public static func write(samples: [UInt8], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var out = Data()
        let dataSize = UInt32(samples.count)
        let riffSize = 36 + dataSize

        out.append(contentsOf: Array("RIFF".utf8))
        out.append(u32LE: riffSize)
        out.append(contentsOf: Array("WAVE".utf8))

        out.append(contentsOf: Array("fmt ".utf8))
        out.append(u32LE: 16)                 // PCM chunk size
        out.append(u16LE: 1)                  // PCM format
        out.append(u16LE: 1)                  // channels
        out.append(u32LE: UInt32(sampleRate)) // sampleRate
        out.append(u32LE: UInt32(sampleRate)) // byteRate = sr * ch * bytes
        out.append(u16LE: 1)                  // blockAlign
        out.append(u16LE: 8)                  // bitsPerSample

        out.append(contentsOf: Array("data".utf8))
        out.append(u32LE: dataSize)
        out.append(contentsOf: samples)

        try out.write(to: url)
    }
}

private extension Data {
    mutating func append(u16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func append(u32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

public enum AssetgenError: Error, CustomStringConvertible {
    case pngCreateFailed(URL)
    case missingFallbackPalette

    public var description: String {
        switch self {
        case .pngCreateFailed(let url): return "failed to write PNG at \(url.path)"
        case .missingFallbackPalette: return "IBM.PAL not found — cannot render paletted images"
        }
    }
}
