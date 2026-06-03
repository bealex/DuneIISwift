import Foundation

/// Decoder for VOC (Creative Voice File) sound effects. Ported from the block parse in OpenDUNE's
/// DSP backend (`src/audio/dsp_sdl.c:131`) plus the standard VOC block structure.
///
/// A 26-byte header whose uint16 at offset 20 points to the first data block. Type-0x01 sound blocks
/// carry a frequency divisor and codec byte followed by unsigned 8-bit mono PCM. Sample rate is
/// `1_000_000 / (256 - frequencyDivisor)`. See `Documentation/Formats/Voc.md`.
public enum Voc {
    public enum DecodeError: Error, Equatable {
        case truncated
    }

    public struct Sound: Equatable {
        public let sampleRate: Int
        /// Unsigned 8-bit mono PCM (silence = 0x80).
        public let samples: [UInt8]
    }

    public static func decode(_ data: Data) throws -> Sound {
        let bytes = [UInt8](data)
        guard bytes.count >= 26 else { throw DecodeError.truncated }

        var cursor = bytes.u16LE(at: 20)  // offset to the first data block
        var sampleRate = 0
        var samples: [UInt8] = []

        while cursor < bytes.count {
            let blockType = bytes[cursor]
            if blockType == 0x00 { break }  // terminator

            guard cursor + 4 <= bytes.count else { throw DecodeError.truncated }

            let blockLength = bytes.u32LE(at: cursor) >> 8  // 24-bit body length
            let body = cursor + 4
            guard body + blockLength <= bytes.count else { throw DecodeError.truncated }

            switch blockType {
                case 0x01:
                    // [frequencyDivisor u8][codec u8][PCM...]
                    guard blockLength >= 2 else { break }

                    let frequencyDivisor = Int(bytes[body])
                    if sampleRate == 0 { sampleRate = 1_000_000 / (256 - frequencyDivisor) }
                    samples.append(contentsOf: bytes[(body + 2) ..< (body + blockLength)])
                case 0x02:
                    // Continuation: raw PCM reusing the prior rate/codec.
                    samples.append(contentsOf: bytes[body ..< (body + blockLength)])
                default:
                    break
            }

            cursor = body + blockLength
        }

        return Sound(sampleRate: sampleRate, samples: samples)
    }
}
