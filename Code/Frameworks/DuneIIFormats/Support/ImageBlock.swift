import Foundation

/// Decoder for a Westwood "image block" — the body of a CPS file and the SSET tile chunk of an ICN
/// file share this small dispatch on a leading compression-type byte. Ported from `Sprites_Decode`
/// (OpenDUNE `src/sprites.c:186`). Type `0x0` = raw, type `0x4` = Format80; other Westwood types
/// (LZW/RLE) are unused by Dune II 1.07 and unsupported.
enum ImageBlock {
    enum DecodeError: Error, Equatable {
        case truncated
        case unsupportedCompression
    }

    static func decode(_ source: [UInt8]) throws -> [UInt8] {
        guard !source.isEmpty else { throw DecodeError.truncated }

        switch source[0] {
            case 0x0:
                var p = 2
                guard p + 4 <= source.count else { throw DecodeError.truncated }

                let size = source.u32LE(at: p)
                p += 4
                guard p + 2 <= source.count else { throw DecodeError.truncated }

                p += source.u16LE(at: p) + 2
                guard p + size <= source.count else { throw DecodeError.truncated }

                return Array(source[p ..< p + size])
            case 0x4:
                var p = 6
                guard p + 2 <= source.count else { throw DecodeError.truncated }

                p += source.u16LE(at: p) + 2
                guard p <= source.count else { throw DecodeError.truncated }

                return [UInt8](try Format80.decodeToEnd(Data(source[p...])))
            default:
                throw DecodeError.unsupportedCompression
        }
    }
}
