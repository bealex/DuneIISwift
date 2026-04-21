import Foundation

extension Codec {
    /// Format80 is Westwood's LZ77-style codec used for CPS, WSA and SHP payloads.
    ///
    /// Reference: OpenDUNE `src/codec/format80.c` (`Format80_Decode`).
    /// The encoded stream is a sequence of commands:
    ///
    /// - `0x80`                                          → end
    /// - `0xFE LL LH V`                                  → long fill of length `LH:LL` with value `V`
    /// - `0xFF LL LH OL OH`                              → long absolute copy from `start+(OH:OL)`
    /// - `cmd` with bit7=1 and bit6=1 (not 0xFE/0xFF):   → short absolute copy (len = (cmd & 0x3F) + 3)
    /// - `cmd` with bit7=0:                              → short relative copy, len = (cmd >> 4) + 3,
    ///                                                     offset = ((cmd & 0x0F) << 8) | next
    /// - `cmd` with bit7=1 and bit6=0:                   → short literal copy, len = cmd & 0x3F
    public enum Format80 {
        public enum DecodeError: Error, Equatable, Sendable {
            case truncated
            case destinationOverflow
        }

        public static func decode(_ source: Data, destinationCapacity: Int) throws -> Data {
            var out = Data(count: destinationCapacity)
            let written = try out.withUnsafeMutableBytes { outBuf -> Int in
                try source.withUnsafeBytes { srcBuf -> Int in
                    try decodeCore(
                        src: srcBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        srcCount: srcBuf.count,
                        dst: outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        dstCapacity: outBuf.count
                    )
                }
            }
            out.removeSubrange(written..<out.count)
            return out
        }


        private static func decodeCore(
            src: UnsafePointer<UInt8>,
            srcCount: Int,
            dst: UnsafeMutablePointer<UInt8>,
            dstCapacity: Int
        ) throws -> Int {
            var sp = 0
            var dp = 0

            func readByte() throws -> UInt8 {
                guard sp < srcCount else { throw DecodeError.truncated }
                let v = src[sp]
                sp += 1
                return v
            }

            while dp < dstCapacity {
                let cmd = try readByte()

                if cmd == 0x80 {
                    break
                } else if (cmd & 0x80) == 0 {
                    // Short relative copy. Length in high nibble + 3, offset in low nibble + next byte.
                    var size = Int(cmd >> 4) + 3
                    if size > dstCapacity - dp { size = dstCapacity - dp }
                    let low = try readByte()
                    let offset = (Int(cmd & 0x0F) << 8) | Int(low)
                    guard offset <= dp else { throw DecodeError.truncated }
                    for _ in 0..<size {
                        dst[dp] = dst[dp - offset]
                        dp += 1
                    }
                } else if cmd == 0xFE {
                    // Long fill.
                    let lo = try readByte()
                    let hi = try readByte()
                    var size = (Int(hi) << 8) | Int(lo)
                    if size > dstCapacity - dp { size = dstCapacity - dp }
                    let value = try readByte()
                    for _ in 0..<size {
                        dst[dp] = value
                        dp += 1
                    }
                } else if cmd == 0xFF {
                    // Long absolute copy. May read from positions that are
                    // simultaneously being written to — valid format80 uses
                    // this for run-length fills, so no bounds check beyond
                    // the destination capacity.
                    let slo = try readByte()
                    let shi = try readByte()
                    var size = (Int(shi) << 8) | Int(slo)
                    if size > dstCapacity - dp { size = dstCapacity - dp }
                    let olo = try readByte()
                    let ohi = try readByte()
                    var offset = (Int(ohi) << 8) | Int(olo)
                    for _ in 0..<size {
                        dst[dp] = dst[offset]
                        dp += 1
                        offset += 1
                    }
                } else if (cmd & 0x40) != 0 {
                    // Short absolute copy. Same forward-overlap rule as 0xFF.
                    var size = Int(cmd & 0x3F) + 3
                    if size > dstCapacity - dp { size = dstCapacity - dp }
                    let olo = try readByte()
                    let ohi = try readByte()
                    var offset = (Int(ohi) << 8) | Int(olo)
                    for _ in 0..<size {
                        dst[dp] = dst[offset]
                        dp += 1
                        offset += 1
                    }
                } else {
                    // Short literal copy.
                    var size = Int(cmd & 0x3F)
                    if size > dstCapacity - dp { size = dstCapacity - dp }
                    for _ in 0..<size {
                        dst[dp] = try readByte()
                        dp += 1
                    }
                }
            }
            return dp
        }
    }
}
