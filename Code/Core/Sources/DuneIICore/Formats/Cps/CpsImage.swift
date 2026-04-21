import Foundation

extension Formats {
    public enum Cps {
        /// CPS is a 320×200 8-bit paletted full-screen image, usually
        /// compressed with Format80. Some entries carry a short embedded
        /// palette right after the header.
        ///
        /// Reference: OpenDUNE `src/sprites.c` · `Sprites_LoadCPSFile` and
        /// `Sprites_Decode`.
        public struct Image: Sendable, Equatable {
            public static let width = 320
            public static let height = 200
            public static let pixelCount = width * height // 64_000

            public enum Compression: UInt16, Sendable {
                case none = 0x0000
                case format80 = 0x0004
            }

            public let compression: Compression
            public let palette: Palette?
            /// 320 × 200 palette indices, row-major.
            public let pixels: [UInt8]
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case truncatedHeader
            case unsupportedCompression(UInt16)
            case paletteTooLarge(UInt16)
            case decodedSizeMismatch(expected: Int, actual: Int)
        }

        public static func decode(_ data: Data) throws -> Image {
            guard data.count >= 10 else { throw DecodeError.truncatedHeader }
            let base = data.startIndex

            // Header: 2-byte file-size-minus-2, 2-byte compression tag,
            //         4-byte decoded size, 2-byte palette size.
            // `fileSize` is unused — we trust the incoming Data length.
            let compressionTag = readU16LE(data, at: base + 2)
            let decodedSize = readU32LE(data, at: base + 4)
            let paletteSize = readU16LE(data, at: base + 8)

            guard let compression = Image.Compression(rawValue: compressionTag) else {
                throw DecodeError.unsupportedCompression(compressionTag)
            }
            guard paletteSize <= 768 else { throw DecodeError.paletteTooLarge(paletteSize) }

            var cursor = base + 10

            let palette: Palette?
            if paletteSize > 0 {
                let paletteData = data.subdata(in: cursor..<(cursor + Int(paletteSize)))
                palette = try Palette.fromPartial(paletteData)
                cursor += Int(paletteSize)
            } else {
                palette = nil
            }

            let payload = data.subdata(in: cursor..<data.endIndex)
            let pixels: [UInt8]
            switch compression {
            case .none:
                guard payload.count >= Int(decodedSize) else {
                    throw DecodeError.decodedSizeMismatch(expected: Int(decodedSize), actual: payload.count)
                }
                pixels = Array(payload.prefix(Int(decodedSize)))
            case .format80:
                let decoded = try Codec.Format80.decode(payload, destinationCapacity: Int(decodedSize))
                guard decoded.count == Int(decodedSize) else {
                    throw DecodeError.decodedSizeMismatch(expected: Int(decodedSize), actual: decoded.count)
                }
                pixels = Array(decoded)
            }
            return Image(compression: compression, palette: palette, pixels: pixels)
        }

        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }

        private static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
    }
}
