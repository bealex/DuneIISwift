import Foundation

extension Formats {
    public enum Shp {
        /// A collection of sprite frames packed into a single SHP file.
        /// Dune II uses SHP for units, structures, HUD icons, and cursors.
        ///
        /// Reference: OpenDUNE `src/sprites.c` · `Sprites_Load` (file-level
        /// header), `src/gui/gui.c` · `GUI_DrawSprite` (frame-level header).
        public struct FrameSet: Sendable {
            public struct Frame: Sendable, Equatable {
                public let width: Int
                public let height: Int
                public let flags: UInt16
                /// 16-entry house remap palette if `flags & 0x0001` is set.
                public let housePalette: [UInt8]?
                /// width × height bytes of palette indices, row-major.
                public let pixels: [UInt8]

                public var hasHousePalette: Bool { (flags & 0x0001) != 0 }
                public var wasFormat80Encoded: Bool { (flags & 0x0002) == 0 }
            }

            public enum FileFormat: Sendable {
                case modern // v1.07: u32 offsets
                case legacy // v1.00: u16 offsets
            }

            public let format: FileFormat
            public let frames: [Frame]
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case truncatedHeader
            case frameTruncated(index: Int)
            case decodedSizeMismatch(index: Int, expected: Int, actual: Int)
        }

        public static func decode(_ data: Data) throws -> FrameSet {
            guard data.count >= 6 else { throw DecodeError.truncatedHeader }
            let base = data.startIndex

            let count = Int(readU16LE(data, at: base))
            // Heuristic from OpenDUNE Sprites_Load: if the u32 right after the
            // count equals 4 + count*4, the file uses 32-bit offsets (modern);
            // otherwise it uses 16-bit offsets (Dune2 v1.0).
            let firstCandidate = readU32LE(data, at: base + 2)
            let isModern = firstCandidate == UInt32(4 + count * 4)
            let format: FrameSet.FileFormat = isModern ? .modern : .legacy

            var frames: [FrameSet.Frame] = []
            frames.reserveCapacity(count)
            for i in 0..<count {
                let offset: Int
                if isModern {
                    offset = Int(readU32LE(data, at: base + 2 + i * 4))
                } else {
                    offset = Int(readU16LE(data, at: base + 2 + i * 2))
                }
                guard offset >= 0, offset < data.count else {
                    throw DecodeError.frameTruncated(index: i)
                }
                // Modern format: skip an extra 2 bytes of "RLE type / file tag"
                // before the real frame header (see Sprites_Load at sprites.c:98).
                let frameStart = isModern ? offset + 2 : offset
                frames.append(try decodeFrame(data, start: frameStart, index: i))
            }
            return FrameSet(format: format, frames: frames)
        }

        private static func decodeFrame(_ data: Data, start: Int, index: Int) throws -> FrameSet.Frame {
            guard start + 10 <= data.count else { throw DecodeError.frameTruncated(index: index) }
            let base = data.startIndex + start
            let flags = readU16LE(data, at: base)
            let height = Int(data[base + 2])
            let width = Int(readU16LE(data, at: base + 3))
            // data[base+5] is height duplicated; ignored.
            // data[base+6..+7] is packed size including header; ignored.
            let decodedSize = Int(readU16LE(data, at: base + 8))

            var cursor = base + 10
            var housePalette: [UInt8]? = nil
            if (flags & 0x0001) != 0 {
                guard cursor + 16 <= data.endIndex else { throw DecodeError.frameTruncated(index: index) }
                housePalette = Array(data[cursor..<(cursor + 16)])
                cursor += 16
            }

            // Both code paths produce a *row RLE stream* of `decodedSize` bytes.
            // It is NOT a flat pixel buffer — it uses (0, N) runs for transparent
            // pixels. See GUI_DrawSprite at gui.c:1247 for the expansion logic.
            let rleStream: [UInt8]
            if (flags & 0x0002) != 0 {
                guard cursor + decodedSize <= data.endIndex else {
                    throw DecodeError.frameTruncated(index: index)
                }
                rleStream = Array(data[cursor..<(cursor + decodedSize)])
            } else {
                let tail = data.subdata(in: cursor..<data.endIndex)
                let decoded = try Codec.Format80.decode(tail, destinationCapacity: decodedSize)
                guard decoded.count == decodedSize else {
                    throw DecodeError.decodedSizeMismatch(index: index, expected: decodedSize, actual: decoded.count)
                }
                rleStream = Array(decoded)
            }

            let pixels = try expandRowRLE(rleStream, width: width, height: height, index: index)
            return FrameSet.Frame(
                width: width,
                height: height,
                flags: flags,
                housePalette: housePalette,
                pixels: pixels
            )
        }

        /// Expands the per-row RLE stream into a width×height pixel buffer.
        /// Palette index 0 = transparent in Westwood sprites, and the encoder
        /// writes `00 N` to mean "N transparent pixels". Non-zero bytes are
        /// literal palette indices.
        private static func expandRowRLE(_ stream: [UInt8], width: Int, height: Int, index: Int) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: width * height)
            var sp = 0
            var dp = 0
            while dp < out.count {
                guard sp < stream.count else {
                    throw DecodeError.decodedSizeMismatch(index: index, expected: out.count, actual: dp)
                }
                let byte = stream[sp]; sp += 1
                if byte == 0 {
                    guard sp < stream.count else {
                        throw DecodeError.decodedSizeMismatch(index: index, expected: out.count, actual: dp)
                    }
                    let run = Int(stream[sp]); sp += 1
                    let clamped = min(run, out.count - dp)
                    // Already zero-initialised; just advance.
                    dp += clamped
                } else {
                    out[dp] = byte
                    dp += 1
                }
            }
            return out
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
