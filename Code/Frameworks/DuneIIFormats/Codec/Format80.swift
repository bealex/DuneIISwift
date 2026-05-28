import Foundation

/// Decoder for Westwood's "Format80" (a.k.a. LCW) compression, used throughout Dune II's data
/// (SHP/ICN sprite frames, CPS images, WSA frames, …). Ported from OpenDUNE
/// `src/codec/format80.c:16` (`Format80_Decode`).
///
/// We only decode: the original tools compressed the data and the engine never recompresses, so —
/// like OpenDUNE — there is no encoder. The decoded length is known from the containing format's
/// header and is passed in. Decoding stops at the `0x80` end marker or when the destination is full.
/// See `Documentation/Formats/Format80.md` for the command table and a worked example.
public enum Format80 {
    public enum DecodeError: Error, Equatable {
        /// The source ran out of bytes in the middle of a command.
        case truncatedSource
        /// A back-reference addressed bytes outside the destination buffer (corrupt stream). The C
        /// reference would read out of bounds here; we throw instead.
        case invalidBackReference
    }

    /// Decode `source` into a buffer of `destinationLength` bytes (or fewer, if the stream ends
    /// early with `0x80`). All copies are byte-by-byte, so overlapping back-references replicate.
    public static func decode(_ source: Data, destinationLength: Int) throws -> Data {
        guard destinationLength > 0 else { return Data() }

        let bytes = [UInt8](source)
        var dest = [UInt8](repeating: 0, count: destinationLength)
        var sourceIndex = 0
        var written = 0

        func nextByte() throws -> Int {
            guard sourceIndex < bytes.count else { throw DecodeError.truncatedSource }

            defer { sourceIndex += 1 }
            return Int(bytes[sourceIndex])
        }

        while written < destinationLength {
            let cmd = try nextByte()

            if cmd == 0x80 {
                // End of stream.
                break
            } else if (cmd & 0x80) == 0 {
                // Short copy, relative: size 3–10, 12-bit offset relative to the write position.
                let size = min((cmd >> 4) + 3, destinationLength - written)
                let offset = ((cmd & 0x0F) << 8) + (try nextByte())
                guard offset <= written else { throw DecodeError.invalidBackReference }

                for _ in 0 ..< size {
                    dest[written] = dest[written - offset]
                    written += 1
                }
            } else if cmd == 0xFE {
                // Long fill (RLE): repeat a single value.
                var size = try nextByte()
                size += (try nextByte()) << 8
                size = min(size, destinationLength - written)
                let value = UInt8(try nextByte())
                for _ in 0 ..< size {
                    dest[written] = value
                    written += 1
                }
            } else if cmd == 0xFF {
                // Long copy, absolute: 16-bit size, 16-bit offset from the start of the output.
                var size = try nextByte()
                size += (try nextByte()) << 8
                size = min(size, destinationLength - written)
                var offset = try nextByte()
                offset += (try nextByte()) << 8
                guard offset + size <= destinationLength else { throw DecodeError.invalidBackReference }

                for _ in 0 ..< size {
                    dest[written] = dest[offset]
                    written += 1
                    offset += 1
                }
            } else if (cmd & 0x40) != 0 {
                // Short copy, absolute: size 3–64, 16-bit offset from the start of the output.
                let size = min((cmd & 0x3F) + 3, destinationLength - written)
                var offset = try nextByte()
                offset += (try nextByte()) << 8
                guard offset + size <= destinationLength else { throw DecodeError.invalidBackReference }

                for _ in 0 ..< size {
                    dest[written] = dest[offset]
                    written += 1
                    offset += 1
                }
            } else {
                // Literal run: copy size bytes verbatim from the source.
                let size = min(cmd & 0x3F, destinationLength - written)
                for _ in 0 ..< size {
                    dest[written] = UInt8(try nextByte())
                    written += 1
                }
            }
        }

        return Data(dest[0 ..< written])
    }

    /// Decode until the `0x80` end marker, growing the output. For streams whose decoded length is
    /// not known up front (CPS image bodies, ICN tile data); mirrors a `Format80_Decode` call with an
    /// effectively unbounded destination (`destLength = 0xFFFF` in OpenDUNE's `Sprites_Decode`).
    public static func decodeToEnd(_ source: Data) throws -> Data {
        let bytes = [UInt8](source)
        var dest: [UInt8] = []
        var sourceIndex = 0

        func nextByte() throws -> Int {
            guard sourceIndex < bytes.count else { throw DecodeError.truncatedSource }

            defer { sourceIndex += 1 }
            return Int(bytes[sourceIndex])
        }

        func copyAbsolute(size: Int, from offset: Int) throws {
            var read = offset
            for _ in 0 ..< size {
                guard read >= 0, read < dest.count else { throw DecodeError.invalidBackReference }

                dest.append(dest[read])
                read += 1
            }
        }

        while true {
            let cmd = try nextByte()

            if cmd == 0x80 {
                break
            } else if (cmd & 0x80) == 0 {
                let size = (cmd >> 4) + 3
                let offset = ((cmd & 0x0F) << 8) + (try nextByte())
                guard offset >= 1, offset <= dest.count else { throw DecodeError.invalidBackReference }

                for _ in 0 ..< size {
                    dest.append(dest[dest.count - offset])
                }
            } else if cmd == 0xFE {
                var size = try nextByte()
                size += (try nextByte()) << 8
                let value = UInt8(try nextByte())
                dest.append(contentsOf: repeatElement(value, count: size))
            } else if cmd == 0xFF {
                var size = try nextByte()
                size += (try nextByte()) << 8
                var offset = try nextByte()
                offset += (try nextByte()) << 8
                try copyAbsolute(size: size, from: offset)
            } else if (cmd & 0x40) != 0 {
                let size = (cmd & 0x3F) + 3
                var offset = try nextByte()
                offset += (try nextByte()) << 8
                try copyAbsolute(size: size, from: offset)
            } else {
                let size = cmd & 0x3F
                for _ in 0 ..< size {
                    dest.append(UInt8(try nextByte()))
                }
            }
        }

        return Data(dest)
    }
}
