import Foundation

extension Formats {
    public enum Fnt {
        /// Bitmap font, 4 bits per pixel. Dune II ships three: `INTRO.FNT`,
        /// `NEW6P.FNT`, `NEW8P.FNT` (plus the German `new6pg.fnt`). Each
        /// glyph is stored as packed 4-bit indices into a small per-file
        /// color palette; the drawing code treats 0 as transparent.
        ///
        /// Reference: OpenDUNE `src/gui/font.c` · `Font_LoadFile`.
        public struct Font: Sendable {
            public struct Glyph: Sendable, Equatable {
                public let width: Int
                public let unusedLines: Int  // blank rows above usedLines
                public let usedLines: Int    // rows of real pixel data
                /// `width * usedLines` palette indices (0…15). Empty if the
                /// glyph has no data.
                public let pixels: [UInt8]

                /// Total rendered height = unusedLines + usedLines.
                public var fullHeight: Int { unusedLines + usedLines }
            }

            public let height: Int
            public let maxWidth: Int
            public let glyphs: [Glyph]

            public subscript(c: Character) -> Glyph? {
                guard let scalar = c.unicodeScalars.first, scalar.value < UInt32(glyphs.count) else {
                    return nil
                }
                return glyphs[Int(scalar.value)]
            }
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case badMagic
            case truncated
        }

        public static func decode(_ data: Data) throws -> Font {
            guard data.count >= 14 else { throw DecodeError.truncated }
            let base = data.startIndex

            // Magic bytes at [2..3] are fixed to 0x00 0x05.
            guard data[base + 2] == 0x00, data[base + 3] == 0x05 else { throw DecodeError.badMagic }

            let start = Int(readU16LE(data, at: base + 4))
            let dataStart = Int(readU16LE(data, at: base + 6))
            let widthList = Int(readU16LE(data, at: base + 8))
            let widthListEnd = Int(readU16LE(data, at: base + 10))
            let lineList = Int(readU16LE(data, at: base + 12))

            guard start + 6 <= data.count else { throw DecodeError.truncated }
            let height = Int(data[base + start + 4])
            let maxWidth = Int(data[base + start + 5])
            let count = widthListEnd - widthList

            var glyphs: [Font.Glyph] = []
            glyphs.reserveCapacity(count)
            for i in 0..<count {
                guard base + widthList + i < data.count,
                      base + lineList + i * 2 + 1 < data.count,
                      base + dataStart + i * 2 + 1 < data.count else {
                    throw DecodeError.truncated
                }
                let width = Int(data[base + widthList + i])
                let unusedLines = Int(data[base + lineList + i * 2])
                let usedLines = Int(data[base + lineList + i * 2 + 1])
                let dataOffset = Int(readU16LE(data, at: base + dataStart + i * 2))
                if dataOffset == 0 || width == 0 || usedLines == 0 {
                    glyphs.append(Font.Glyph(width: width, unusedLines: unusedLines, usedLines: usedLines, pixels: []))
                    continue
                }
                var pixels = [UInt8](repeating: 0, count: width * usedLines)
                let rowStride = (width + 1) / 2
                for y in 0..<usedLines {
                    for x in 0..<width {
                        let byteOffset = base + dataOffset + y * rowStride + (x / 2)
                        guard byteOffset < data.count else { throw DecodeError.truncated }
                        let raw = data[byteOffset]
                        let nibble = (x % 2 == 0) ? (raw & 0x0F) : (raw >> 4)
                        pixels[y * width + x] = nibble
                    }
                }
                glyphs.append(Font.Glyph(width: width, unusedLines: unusedLines, usedLines: usedLines, pixels: pixels))
            }

            return Font(height: height, maxWidth: maxWidth, glyphs: glyphs)
        }

        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
    }
}
