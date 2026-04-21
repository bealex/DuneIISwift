import Foundation

extension Formats {
    /// VGA 6-bit palette: 256 × (R, G, B) triplets where each channel is 0…63.
    /// The on-disk file is exactly 768 bytes (`256 * 3`). See OpenDUNE's
    /// `File_ReadBlockFile("IBM.PAL", g_palette1, 256 * 3)` in `opendune.c`.
    public struct Palette: Sendable, Equatable {
        public static let entryCount = 256

        public struct Color: Sendable, Equatable, Hashable {
            public let r6: UInt8 // 0…63
            public let g6: UInt8
            public let b6: UInt8

            /// Scales 6-bit VGA values to full 8-bit range via bit replication.
            public var rgba8: UInt32 {
                let r = (UInt32(r6) << 2) | (UInt32(r6) >> 4)
                let g = (UInt32(g6) << 2) | (UInt32(g6) >> 4)
                let b = (UInt32(b6) << 2) | (UInt32(b6) >> 4)
                return (r << 24) | (g << 16) | (b << 8) | 0xFF
            }
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case wrongSize(Int)
            case channelOutOfRange
        }

        public let colors: [Color]

        public init(data: Data) throws {
            let expected = Self.entryCount * 3
            guard data.count == expected else { throw DecodeError.wrongSize(data.count) }
            var colors: [Color] = []
            colors.reserveCapacity(Self.entryCount)
            var i = data.startIndex
            for _ in 0..<Self.entryCount {
                let r = data[i]; i += 1
                let g = data[i]; i += 1
                let b = data[i]; i += 1
                guard r < 64, g < 64, b < 64 else { throw DecodeError.channelOutOfRange }
                colors.append(Color(r6: r, g6: g, b6: b))
            }
            self.colors = colors
        }

        /// Produce a flat RGBA8 buffer (256 × 4 bytes) in big-endian RGBA order.
        public func rgba8Buffer() -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(Self.entryCount * 4)
            for c in colors {
                let packed = c.rgba8
                out.append(UInt8((packed >> 24) & 0xFF))
                out.append(UInt8((packed >> 16) & 0xFF))
                out.append(UInt8((packed >> 8) & 0xFF))
                out.append(UInt8(packed & 0xFF))
            }
            return out
        }

        /// Partial palette (e.g. CPS-embedded palettes cover only the first N colors).
        /// Unused slots get filled with black.
        public static func fromPartial(_ data: Data) throws -> Palette {
            guard data.count % 3 == 0 else { throw DecodeError.wrongSize(data.count) }
            let partialEntries = data.count / 3
            guard partialEntries <= Self.entryCount else { throw DecodeError.wrongSize(data.count) }
            var padded = Data(count: Self.entryCount * 3)
            padded.replaceSubrange(0..<data.count, with: data)
            return try Palette(data: padded)
        }
    }
}
