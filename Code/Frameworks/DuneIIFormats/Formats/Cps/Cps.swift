import Foundation

/// Decoder for CPS full-screen images (320×200, 8-bit). Ported from `Sprites_LoadCPSFile`
/// (OpenDUNE `src/sprites.c:299`) + `Sprites_Decode`. Header: uint16 LE file size, then an 8-byte
/// block [compression-type u16][uncompressed-size u32][palette-size u16]; an optional embedded
/// palette of `palette-size` bytes (768 = a full VGA palette) follows, then the image body
/// (Format80, or raw). See `Documentation/Formats/Cps.md`.
public enum Cps {
    public enum DecodeError: Error, Equatable {
        case truncated
    }

    public struct Image: Equatable {
        public let width: Int
        public let height: Int
        /// Row-major 8-bit palette indices (320×200 = 64000 for a standard CPS).
        public let pixels: [UInt8]
        /// The embedded palette, when the file carries one.
        public let palette: Palette?
    }

    public static func decode(_ data: Data) throws -> Image {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { throw DecodeError.truncated }

        let paletteSize = bytes.u16LE(at: 8)
        let imageStart = 10 + paletteSize
        guard imageStart <= bytes.count else { throw DecodeError.truncated }

        var palette: Palette?
        if paletteSize >= Palette.colorCount * 3 {
            palette = try? Palette(Data(bytes[10 ..< 10 + Palette.colorCount * 3]))
        }

        // Reconstruct the block OpenDUNE feeds to Sprites_Decode: the 8-byte header (with the
        // palette-size field zeroed so the decoder doesn't skip into the image) + the image body.
        var block = Array(bytes[2 ..< 10])
        block[6] = 0
        block[7] = 0
        block.append(contentsOf: bytes[imageStart...])

        let pixels = try ImageBlock.decode(block)
        let width = 320
        let height = width > 0 ? pixels.count / width : 0
        return Image(width: width, height: height, pixels: pixels, palette: palette)
    }
}
