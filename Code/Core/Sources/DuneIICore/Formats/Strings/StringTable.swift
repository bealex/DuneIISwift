import Foundation

extension Formats {
    /// Dune II `.ENG` / `.FRE` / `.GER` / `.ITA` / `.SPA` string table.
    ///
    /// File layout: a little-endian `UInt16` offset table at the top
    /// (the first offset indirectly gives the entry count — table size
    /// in bytes = first-offset), followed by the null-terminated
    /// strings. Some tables (`DUNE`, `MESSAGE`, `INTRO`) store plain
    /// ASCII; others (`TEXTH`, `TEXTA`, `TEXTO`, `PROTECT`) use a
    /// byte-pair / couples compression. See
    /// `Repositories/OpenDUNE/src/string.c:42..165`.
    ///
    /// Compression: every byte with the high bit set expands to **two**
    /// characters drawn from a fixed 144-byte couples table — the high
    /// four bits pick a "first character" from the top 16 entries and
    /// the whole 7 bits, when added to `16`, pick the "second character"
    /// from the subsequent 8-char sub-tables. A `0x1B` byte introduces
    /// an extended ASCII literal (`0x7F + next_byte`). Everything else
    /// is a literal.
    public enum Strings {

        public enum DecodeError: Error, Equatable, Sendable {
            case truncatedHeader
            case truncatedString(index: Int)
            case invalidOffset(index: Int, offset: UInt16)
        }

        /// `const char couples[]` from `src/string.c:44..61`. 144 bytes:
        /// the first 16 are the "1st-character" pool, indexed by
        /// `c >> 3` (the high 4 bits of the compressed byte); the
        /// remaining 128 are 16 sub-tables of 8 chars each, indexed by
        /// `(c + 16)` where `c` is the full 7-bit packed byte.
        private static let couples: [UInt8] = Array(
            (" etainosrlhcdupm"           // 1st char (16 entries)
             + "tasio wb"                  // <space>?
             + " rnsdalm"                  // e?
             + "h ieoras"                  // t?
             + "nrtlc sy"                  // a?
             + "nstcloer"                  // i?
             + " dtgesio"                  // n?
             + "nr ufmsw"                  // o?
             + " tep.ica"                  // s?
             + "e oiadur"                  // r?
             + " laeiyod"                  // l?
             + "eia otru"                  // h?
             + "etoakhlr"                  // c?
             + " eiu,.oa"                  // d?
             + "nsrctlai"                  // u?
             + "leoiratp"                  // p?
             + "eaoip bm"                  // m?
             ).utf8
        )

        /// Decodes the full contents of a `.ENG`-style string table.
        ///
        /// - `data`: the raw file bytes.
        /// - `compressed`: `true` for `TEXTA` / `TEXTH` / `TEXTO` /
        ///   `PROTECT`; `false` for `DUNE` / `MESSAGE` / `INTRO` /
        ///   per-UI strings.
        ///
        /// Returns the decoded strings in offset-table order. Trailing
        /// whitespace (+ the ASCII control sequences OpenDUNE's
        /// `String_Trim` removes) is stripped.
        public static func decode(
            _ data: Data, compressed: Bool
        ) throws -> [String] {
            guard data.count >= 2 else { throw DecodeError.truncatedHeader }
            let firstOffset = readU16LE(data, at: 0)
            let tableLen = Int(firstOffset)
            guard tableLen % 2 == 0, tableLen <= data.count else {
                throw DecodeError.truncatedHeader
            }
            let count = tableLen / 2
            var result: [String] = []
            result.reserveCapacity(count)
            for i in 0..<count {
                let offset = readU16LE(data, at: i * 2)
                guard Int(offset) < data.count else {
                    throw DecodeError.invalidOffset(index: i, offset: offset)
                }
                // Null-terminated string starting at `offset`.
                var end = Int(offset)
                while end < data.count, data[data.startIndex + end] != 0 {
                    end &+= 1
                }
                guard end < data.count else {
                    throw DecodeError.truncatedString(index: i)
                }
                let body = data.subdata(
                    in: (data.startIndex + Int(offset))..<(data.startIndex + end)
                )
                let raw: String
                if compressed {
                    raw = decompress(body)
                } else {
                    // Plain bytes — assume MS-DOS CP437 subset, which
                    // overlaps with Latin-1 for the 0x20..0x7E range
                    // our strings use. Fall back to lossy UTF-8 for
                    // bytes outside that range.
                    raw = String(data: body, encoding: .isoLatin1) ?? ""
                }
                result.append(trim(raw))
            }
            return result
        }

        /// Port of `String_DecompressAndTranslate` (`src/string.c:42`).
        static func decompress(_ data: Data) -> String {
            var out: [UInt8] = []
            out.reserveCapacity(data.count * 2)
            var i = data.startIndex
            while i < data.endIndex {
                let c = data[i]
                i = data.index(after: i)
                if (c & 0x80) != 0 {
                    // Packed pair: 1AAAABBB. AAAA → 1st char (couples[c>>3]
                    // where the shift keeps the 4-bit high nibble); whole
                    // 7-bit value + 16 → 2nd char.
                    let masked = c & 0x7F
                    let first = couples[Int(masked >> 3)]
                    let second = couples[Int(masked) + 16]
                    out.append(first)
                    out.append(second)
                } else if c == 0x1B {
                    // 0x1B escape → extended literal at 0x7F + next byte.
                    // OpenDUNE reads the next byte unconditionally via
                    // `*(++s)`; a lone trailing 0x1B would read past the
                    // string's NUL. We drop it rather than risk a bogus
                    // unit.
                    if i < data.endIndex {
                        let ext = data[i]
                        i = data.index(after: i)
                        out.append(0x7F &+ ext)
                    }
                } else {
                    out.append(c)
                }
            }
            // `out` holds Latin-1 bytes — the compressed extended
            // range hits 0x80..0xFF, which is not valid UTF-8. Decode
            // as Latin-1 (ISO 8859-1) so every byte maps to the matching
            // Unicode code point; the briefing corpus uses only ASCII
            // plus a handful of ISO-Latin punctuation, which renders
            // as expected.
            return String(data: Data(out), encoding: .isoLatin1) ?? ""
        }

        /// Port of `String_Trim` (`src/string.c`). Strips leading /
        /// trailing spaces + line breaks. OpenDUNE also drops control
        /// bytes < 0x20 inside strings — we keep only 0x0A / 0x0D as
        /// newlines since the briefing text uses them for line breaks.
        static func trim(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @inline(__always)
        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            let base = data.startIndex + offset
            return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
        }
    }
}
