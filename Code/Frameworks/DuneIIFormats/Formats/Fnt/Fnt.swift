import Foundation

/// Decoder for FNT bitmap fonts. Ported from `Font_LoadFile` (OpenDUNE `src/gui/font.c:59`) and
/// `GUI_DrawChar` (`src/gui/gui.c:398`).
///
/// Header offsets (little-endian uint16): a magic `00 05` at bytes 2-3; the font-info block, the
/// glyph data-pointer table, the per-glyph width table, and the per-glyph line table. Glyph bitmaps
/// are 4-bit packed nibbles (low nibble = left pixel, high nibble = right), `(width+1)/2` bytes per
/// row, `usedLines` rows, offset down by `unusedLines`. Color index 0 is transparent. See
/// `Documentation/Formats/Fnt.md`.
public enum Fnt {
    public enum DecodeError: Error, Equatable {
        case invalidMagic
        case truncated
    }

    public struct Glyph: Equatable {
        public let width: Int
        public let topRows: Int  // blank rows above the bitmap (unusedLines)
        public let bitmapRows: Int  // rows actually stored (usedLines)
        /// `width * bitmapRows` 4-bit color indices, row-major. Index 0 is transparent.
        public let pixels: [UInt8]
    }

    public struct Font {
        public let height: Int
        public let maxWidth: Int
        public let glyphs: [Glyph]

        public func glyph(_ code: Int) -> Glyph? {
            code >= 0 && code < glyphs.count ? glyphs[code] : nil
        }

        public init(_ data: Data) throws {
            let bytes = [ UInt8 ](data)
            guard bytes.count >= 14 else { throw DecodeError.truncated }
            guard bytes[2] == 0x00, bytes[3] == 0x05 else { throw DecodeError.invalidMagic }

            let infoStart = bytes.u16LE(at: 4)
            let dataTable = bytes.u16LE(at: 6)
            let widthTable = bytes.u16LE(at: 8)
            let count = bytes.u16LE(at: 10) - widthTable
            let lineTable = bytes.u16LE(at: 12)
            guard count >= 0, infoStart + 6 <= bytes.count else { throw DecodeError.truncated }

            let height = Int(bytes[infoStart + 4])
            let maxWidth = Int(bytes[infoStart + 5])

            var glyphs: [Glyph] = []
            glyphs.reserveCapacity(count)
            for index in 0 ..< count {
                guard
                    widthTable + index < bytes.count,
                    lineTable + index * 2 + 2 <= bytes.count,
                    dataTable + index * 2 + 2 <= bytes.count
                else { throw DecodeError.truncated }

                let width = Int(bytes[widthTable + index])
                let topRows = Int(bytes[lineTable + index * 2])
                let bitmapRows = Int(bytes[lineTable + index * 2 + 1])
                let dataOffset = bytes.u16LE(at: dataTable + index * 2)

                var pixels: [UInt8] = []
                if dataOffset != 0, width > 0, bitmapRows > 0 {
                    let bytesPerRow = (width + 1) / 2
                    pixels.reserveCapacity(width * bitmapRows)
                    for y in 0 ..< bitmapRows {
                        for x in 0 ..< width {
                            let at = dataOffset + y * bytesPerRow + x / 2
                            guard at < bytes.count else { throw DecodeError.truncated }

                            let byte = bytes[at]
                            pixels.append((x & 1) == 1 ? (byte >> 4) : (byte & 0x0F))
                        }
                    }
                }
                glyphs.append(Glyph(width: width, topRows: topRows, bitmapRows: bitmapRows, pixels: pixels))
            }

            self.height = height
            self.maxWidth = maxWidth
            self.glyphs = glyphs
        }
    }
}
