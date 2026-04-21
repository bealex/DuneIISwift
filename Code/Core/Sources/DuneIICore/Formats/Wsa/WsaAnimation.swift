import Foundation

extension Formats {
    public enum Wsa {
        /// WSA is Dune II's pre-rendered animation format (intro, cutscenes,
        /// mentat lip-sync, mission victory screens). Each file is a short
        /// sequence of delta-encoded frames rendered against a shared
        /// running display buffer.
        ///
        /// Reference: OpenDUNE `src/wsa.c`. The pipeline per frame is:
        /// `Format80_Decode` → `Format40_Decode` (XOR into the display buffer).
        public struct Animation: Sendable {
            public let width: Int
            public let height: Int
            public let palette: Palette?
            public let frames: [[UInt8]] // each is width*height palette indices
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case truncatedHeader
            case offsetOutOfRange(index: Int)
            case frameDecodeFailed(index: Int)
        }

        public static func decode(_ data: Data) throws -> Animation {
            guard data.count >= 14 else { throw DecodeError.truncatedHeader }
            let base = data.startIndex

            // 10-byte or 8-byte header. The difference: legacy (v1.0) has no
            // `hasPalette` field. We detect using OpenDUNE's heuristic: the
            // first frame offset should equal lengthHeader + 8 + 4*frames.
            var frames = Int(readU16LE(data, at: base))
            if frames & 0x8000 != 0 { frames &= 0x7FFF }
            let width = Int(readU16LE(data, at: base + 2))
            let height = Int(readU16LE(data, at: base + 4))
            // base+6..7 is "requiredBufferSize" — we size our own working buffer.

            // Peek the candidate first-frame offset in modern layout.
            let modernFirstCandidate = readU32LE(data, at: base + 10)
            let modernExpected = UInt32(10 + 8 + 4 * frames)
            let modernSecondCandidate = readU32LE(data, at: base + 14)
            let isModern = modernFirstCandidate == modernExpected || modernSecondCandidate == modernExpected

            let lengthHeader: Int
            let hasPalette: Bool
            if isModern {
                lengthHeader = 10
                hasPalette = readU16LE(data, at: base + 8) != 0
            } else {
                lengthHeader = 8
                hasPalette = false
            }

            // Offset table: (frames + 2) u32 LE.
            let offsetCount = frames + 2
            guard base + lengthHeader + offsetCount * 4 <= data.endIndex else {
                throw DecodeError.truncatedHeader
            }
            var offsets: [UInt32] = []
            offsets.reserveCapacity(offsetCount)
            for i in 0..<offsetCount {
                offsets.append(readU32LE(data, at: base + lengthHeader + i * 4))
            }

            var paletteOffset = lengthHeader + offsetCount * 4
            var palette: Palette? = nil
            if hasPalette {
                guard paletteOffset + 768 <= data.count else { throw DecodeError.truncatedHeader }
                let palData = data.subdata(in: (base + paletteOffset)..<(base + paletteOffset + 768))
                palette = try? Palette(data: palData)
                paletteOffset += 768
            }

            // The format80 output (a format40 XOR stream) can be larger than
            // width*height. OpenDUNE sizes the working buffer as
            // `requiredBufferSize + 33` — we give it a generous upper bound.
            let workingCap = max(width * height * 2 + 64, Int(readU16LE(data, at: base + 6)) + 64)

            var display = Data(count: width * height)
            var framesOut: [[UInt8]] = []
            framesOut.reserveCapacity(frames)

            for i in 0..<frames {
                let start = Int(offsets[i])
                let end = Int(offsets[i + 1])
                // Continuation WSAs store `offsets[0] == 0` to mean "this file
                // is a continuation — frame 0 lives in the previous file's
                // display buffer". We emit the running display as-is and move on.
                if start == 0 {
                    framesOut.append(Array(display))
                    continue
                }
                guard end > start, end <= data.count else {
                    throw DecodeError.offsetOutOfRange(index: i)
                }
                let compressed = data.subdata(in: (base + start)..<(base + end))
                let xorStream: Data
                do {
                    xorStream = try Codec.Format80.decode(compressed, destinationCapacity: workingCap)
                } catch {
                    throw DecodeError.frameDecodeFailed(index: i)
                }
                do {
                    try Codec.Format40.decode(source: xorStream, destination: &display)
                } catch {
                    throw DecodeError.frameDecodeFailed(index: i)
                }
                framesOut.append(Array(display))
            }

            return Animation(width: width, height: height, palette: palette, frames: framesOut)
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
