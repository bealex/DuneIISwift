import Foundation

/// XOR-delta decoder ("Format40"), used for WSA animation frame deltas. Ported from OpenDUNE
/// `src/codec/format40.c:14` (`Format40_Decode`).
///
/// The stream XORs runs onto an existing destination buffer (the previous frame), mutating it in
/// place into the next frame, until the `0x80 0x00 0x00` terminator. "Skip" commands advance the
/// write position without touching those bytes — they carry over from the previous frame, which is
/// why the running buffer must persist across frames. See `Documentation/Formats/Format40.md`.
public enum Format40 {
    public enum DecodeError: Error, Equatable {
        /// The source ran out of bytes before the terminator.
        case truncatedSource
        /// A run/skip would write past the end of the destination (corrupt stream).
        case destinationOverflow
    }

    /// XOR `source` (a Format40 delta) onto `destination` in place. `destination` must already hold
    /// the previous frame and be sized for the full frame.
    public static func decodeXOR(into destination: inout [UInt8], source: Data) throws {
        let src = [ UInt8 ](source)
        var i = 0
        var d = 0

        func nextByte() throws -> Int {
            guard i < src.count else { throw DecodeError.truncatedSource }

            defer { i += 1 }
            return Int(src[i])
        }

        func xorRun(count: Int, value: Int) throws {
            guard d + count <= destination.count else { throw DecodeError.destinationOverflow }

            for _ in 0 ..< count {
                destination[d] ^= UInt8(value)
                d += 1
            }
        }

        func xorString(count: Int) throws {
            guard d + count <= destination.count else { throw DecodeError.destinationOverflow }

            for _ in 0 ..< count {
                destination[d] ^= UInt8(try nextByte())
                d += 1
            }
        }

        func skip(_ count: Int) throws {
            guard d + count <= destination.count else { throw DecodeError.destinationOverflow }

            d += count
        }

        while true {
            let cmd = try nextByte()

            if cmd == 0 {
                // XOR a single value `count` times.
                let count = try nextByte()
                let value = try nextByte()
                try xorRun(count: count, value: value)
            } else if (cmd & 0x80) == 0 {
                // XOR with a string of `cmd` bytes.
                try xorString(count: cmd)
            } else if cmd != 0x80 {
                // Skip (cmd & 0x7F) destination bytes (unchanged from the previous frame).
                try skip(cmd & 0x7F)
            } else {
                // cmd == 0x80: 16-bit extended command.
                let low = try nextByte()
                let high = try nextByte()
                let value16 = low | (high << 8)

                if value16 == 0 {
                    break  // 0x80 0x00 0x00 => done
                } else if (value16 & 0x8000) == 0 {
                    try skip(value16)
                } else if (value16 & 0x4000) == 0 {
                    try xorString(count: value16 & 0x3FFF)
                } else {
                    let value = try nextByte()
                    try xorRun(count: value16 & 0x3FFF, value: value)
                }
            }
        }
    }
}
