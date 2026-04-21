import Foundation

extension Formats {
    public enum Voc {
        /// Creative Voice file. Dune II uses only the simplest form:
        /// unsigned 8-bit PCM carried in one or more Type-1 blocks.
        ///
        /// Reference: OpenDUNE `src/audio/dsp_sdl.c` · `DSP_Play` decodes
        /// the header + first block exactly as below.
        public struct Sound: Sendable, Equatable {
            public let sampleRate: Int  // Hz
            /// Unsigned 8-bit PCM, mono.
            public let samples: [UInt8]
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case badMagic
            case truncated
            case unsupportedCodec(UInt8)
            case missingSoundBlock
        }

        public static func decode(_ data: Data) throws -> Sound {
            guard data.count >= 26 else { throw DecodeError.truncated }
            let base = data.startIndex

            let magic = "Creative Voice File\u{1A}"
            let magicBytes = Array(magic.utf8)
            for (i, expected) in magicBytes.enumerated() {
                guard data[base + i] == expected else { throw DecodeError.badMagic }
            }

            let dataOffset = Int(readU16LE(data, at: base + 20))
            guard dataOffset < data.count else { throw DecodeError.truncated }

            var cursor = base + dataOffset
            var samples: [UInt8] = []
            var sampleRate = 0

            while cursor < data.endIndex {
                let blockType = data[cursor]
                cursor += 1
                if blockType == 0x00 { break }
                guard cursor + 3 <= data.endIndex else { throw DecodeError.truncated }
                let size = Int(data[cursor]) | (Int(data[cursor + 1]) << 8) | (Int(data[cursor + 2]) << 16)
                cursor += 3
                guard cursor + size <= data.endIndex else { throw DecodeError.truncated }
                let blockBody = cursor..<(cursor + size)
                defer { cursor = blockBody.upperBound }

                switch blockType {
                case 0x01:
                    guard size >= 2 else { throw DecodeError.truncated }
                    let rateDivisor = data[blockBody.lowerBound]
                    let codec = data[blockBody.lowerBound + 1]
                    guard codec == 0 else { throw DecodeError.unsupportedCodec(codec) }
                    if sampleRate == 0 {
                        // Classic VOC rate formula.
                        sampleRate = 1_000_000 / (256 - Int(rateDivisor))
                    }
                    samples.append(contentsOf: data[(blockBody.lowerBound + 2)..<blockBody.upperBound])
                case 0x02:
                    // Continuation of previous type-1 data.
                    samples.append(contentsOf: data[blockBody])
                default:
                    // Silence, marker, repeat, end-repeat, extra info: ignore.
                    break
                }
            }

            guard !samples.isEmpty, sampleRate > 0 else {
                throw DecodeError.missingSoundBlock
            }

            return Sound(sampleRate: sampleRate, samples: samples)
        }

        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
    }
}
