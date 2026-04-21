import Foundation

extension Codec {
    /// Format40 is Westwood's XOR-delta codec used for WSA inter-frame updates.
    ///
    /// Reference: OpenDUNE `src/codec/format40.c` (`Format40_Decode`).
    /// The decoder is applied to an existing destination buffer — commands
    /// either skip bytes, XOR against literal runs, or XOR against a repeated
    /// value. A `0x80 0x00 0x00` sequence ends the stream.
    public enum Format40 {
        public enum DecodeError: Error, Equatable, Sendable {
            case truncated
            case destinationOverflow
        }

        /// XOR-decode `source` into `destination` in place.
        public static func decode(source: Data, destination: inout Data) throws {
            try destination.withUnsafeMutableBytes { dstBuf in
                try source.withUnsafeBytes { srcBuf in
                    try decodeCore(
                        src: srcBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        srcCount: srcBuf.count,
                        dst: dstBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        dstCapacity: dstBuf.count
                    )
                }
            }
        }

        /// Convenience: start from a zeroed destination of the given size.
        public static func decode(source: Data, destinationCapacity: Int) throws -> Data {
            var out = Data(count: destinationCapacity)
            try decode(source: source, destination: &out)
            return out
        }

        private static func decodeCore(
            src: UnsafePointer<UInt8>,
            srcCount: Int,
            dst: UnsafeMutablePointer<UInt8>,
            dstCapacity: Int
        ) throws {
            var sp = 0
            var dp = 0

            func readByte() throws -> UInt8 {
                guard sp < srcCount else { throw DecodeError.truncated }
                let v = src[sp]
                sp += 1
                return v
            }

            func ensureRoom(_ n: Int) throws {
                guard dp + n <= dstCapacity else { throw DecodeError.destinationOverflow }
            }

            while true {
                let cmd = try readByte()

                if cmd == 0 {
                    // XOR with repeated value: 0 LEN V
                    let count = Int(try readByte())
                    let value = try readByte()
                    try ensureRoom(count)
                    for _ in 0..<count {
                        dst[dp] ^= value
                        dp += 1
                    }
                } else if (cmd & 0x80) == 0 {
                    // XOR with string: cmd bytes follow.
                    let count = Int(cmd)
                    try ensureRoom(count)
                    for _ in 0..<count {
                        dst[dp] ^= try readByte()
                        dp += 1
                    }
                } else if cmd != 0x80 {
                    // Skip (cmd & 0x7F) bytes.
                    let skip = Int(cmd & 0x7F)
                    try ensureRoom(skip)
                    dp += skip
                } else {
                    // 0x80 prefix — read 16-bit extended opcode.
                    let lo = try readByte()
                    let hi = try readByte()
                    let extended = (UInt16(hi) << 8) | UInt16(lo)
                    if extended == 0 { return } // exit
                    if (extended & 0x8000) == 0 {
                        // Long skip.
                        let skip = Int(extended)
                        try ensureRoom(skip)
                        dp += skip
                    } else if (extended & 0x4000) == 0 {
                        // Long XOR string.
                        let count = Int(extended & 0x3FFF)
                        try ensureRoom(count)
                        for _ in 0..<count {
                            dst[dp] ^= try readByte()
                            dp += 1
                        }
                    } else {
                        // Long XOR with repeated value.
                        let count = Int(extended & 0x3FFF)
                        let value = try readByte()
                        try ensureRoom(count)
                        for _ in 0..<count {
                            dst[dp] ^= value
                            dp += 1
                        }
                    }
                }
            }
        }
    }
}
