import Foundation

/// Decoder for the Mentat help database (`MENTAT<HOUSE>.ENG` — `MENTATH`/`MENTATA`/`MENTATO`), the per-house
/// advisor's list of help topics + their descriptions. A port of OpenDUNE's `GUI_Mentat_LoadHelpSubjects` /
/// `GUI_Mentat_ShowHelp` (`gui/mentat.c`).
///
/// Layout: an IFF `FORM`/`MENT` file. The `NAME` chunk is a packed list of topic entries; each topic's
/// description text sits at an absolute file offset (named in the entry), compressed with the same
/// char-pair scheme as the `.ENG` string tables (`String_DecompressAndTranslate`, `string.c`).
///
/// Each `NAME` entry: `[size:1][offset:4 BE][section:1][level:1][name…NUL][campaign:1]` (the two ASCII
/// digits before the name are the section `1`–`4` and the level `0`=header/`1`=item; `campaign` is the
/// minimum `campaignID+1` at which the topic appears). The description decompresses to
/// `"<wsa>*<title>\r<attr>\r<attr>\u{0C}<body>"`.
public enum MentatHelp {
    /// The four browsable groups (the `0` "Briefing/Advice/Orders" section is `.general`).
    public enum Section: String, Sendable, Equatable, CaseIterable {
        case general, houses, structures, vehicles, specials

        init(digit: UInt8) {
            switch digit {
                case UInt8(ascii: "1"): self = .houses
                case UInt8(ascii: "2"): self = .structures
                case UInt8(ascii: "3"): self = .vehicles
                case UInt8(ascii: "4"): self = .specials
                default: self = .general
            }
        }
    }

    /// One help topic: its group, name, campaign gate, and parsed description (the animation filename, a
    /// heading, the attribute lines, and the body paragraph).
    public struct Topic: Sendable, Equatable {
        public let section: Section
        /// A section header (`Houses`/`Structures`/…) rather than a real entry — skipped in the topic lists.
        public let isHeader: Bool
        public let name: String
        /// The topic appears once the active `campaignID + 1 >= campaign` (`gui/mentat.c` gating).
        public let campaign: Int
        public let wsa: String
        public let title: String
        public let attributes: [String]
        public let body: String
    }

    public enum DecodeError: Error, Equatable { case noNameChunk }

    /// The `string.c` char-pair table: index 0–15 = the 16 first-chars; 16–143 = the 8 second-chars per
    /// first-char (`couples[(c>>3)<<3 + (c&7) + 16]` = `couples[c+16]`).
    private static let couples = Array(
        " etainosrlhcdupmtasio wb rnsdalmh ieorasnrtlc synstcloer dtgesionr ufmsw tep.icae oiadur laeiyodeia otruetoakhlr eiu,.oansrctlaileoiratpeaoip bm"
            .utf8
    )

    /// Parse every topic from a `MENTAT<HOUSE>.ENG` file.
    public static func topics(_ data: Data) throws -> [Topic] {
        let reader = try Iff.Reader(data)
        guard
            let nameRange = reader.chunks.first(where: { $0.id == "NAME" })?.range
        else {
            throw DecodeError.noNameChunk
        }

        let bytes = [UInt8](data)
        var result: [Topic] = []
        var i = nameRange.lowerBound
        while i < nameRange.upperBound {
            let size = Int(bytes[i])
            if size < 8 || i + size > nameRange.upperBound { break }
            let entry = Array(bytes[i ..< i + size])
            let offset = Int(entry[1]) << 24 | Int(entry[2]) << 16 | Int(entry[3]) << 8 | Int(entry[4])
            let section = Section(digit: entry[5])
            let isHeader = entry[6] == UInt8(ascii: "0")
            // Name runs from byte 7 to the NUL; the campaign gate is the entry's last byte.
            var end = 7
            while end < size && entry[end] != 0 { end += 1 }
            let name = String(decoding: entry[7 ..< end], as: UTF8.self)
            let campaign = Int(entry[size - 1])
            let (wsa, title, attrs, body) = parseDescription(decompress(bytes, at: offset))
            result.append(
                Topic(
                    section: section,
                    isHeader: isHeader,
                    name: name,
                    campaign: campaign,
                    wsa: wsa,
                    title: title,
                    attributes: attrs,
                    body: body
                )
            )
            i += size
        }
        return result
    }

    /// Split a decompressed description `"<wsa>*<title>\r<attr>…\u{0C}<body>"` into its parts. The leading
    /// animation name is terminated by `*` (a structured description) or `?` (`GUI_Mentat_ShowHelp`'s
    /// "no description" topics, e.g. the section headers — the remainder is a string-table index, not literal
    /// text, so there is nothing to display).
    static func parseDescription(_ text: String) -> (wsa: String, title: String, attrs: [String], body: String) {
        guard
            let sep = text.firstIndex(where: { $0 == "*" || $0 == "?" })
        else {
            return ("", text.trimmed, [], "")
        }

        let wsa = String(text[..<sep])
        if text[sep] == "?" { return (wsa, "", [], "") }
        let rest = String(text[text.index(after: sep)...])
        let header: String, body: String
        if let ff = rest.firstIndex(of: "\u{0C}") {
            header = String(rest[..<ff]); body = String(rest[rest.index(after: ff)...]).trimmed
        } else {
            header = rest; body = ""
        }
        var lines = header.split(separator: "\r", omittingEmptySubsequences: false).map { String($0).trimmed }
        let title = lines.first ?? ""
        lines.removeFirst()
        return (wsa, title, lines.filter { !$0.isEmpty }, body)
    }

    /// `String_DecompressAndTranslate` (`string.c:88`): expand the char-pair compression starting at `offset`,
    /// stopping at the first NUL. A high-bit byte encodes a 2-char pair via the `couples` table; `0x1B` escapes
    /// the next byte to `0x7F + b`.
    static func decompress(_ bytes: [UInt8], at offset: Int) -> String {
        guard offset >= 0, offset < bytes.count else { return "" }

        let couples = Self.couples
        var out: [UInt8] = []
        var i = offset
        while i < bytes.count, bytes[i] != 0 {
            var c = bytes[i]
            if c & 0x80 != 0 {
                c &= 0x7F
                out.append(couples[Int(c) >> 3])  // 1st char of the pair
                out.append(couples[Int(c) + 16])  // 2nd char
                i += 1
                continue
            } else if c == 0x1B {
                i += 1
                guard i < bytes.count else { break }

                c = 0x7F &+ bytes[i]
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
