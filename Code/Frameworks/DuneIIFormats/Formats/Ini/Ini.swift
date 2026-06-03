import Foundation

/// Parser for the scenario / config `.INI` text format. Ported from the semantics of `Ini_GetString`
/// / `Ini_GetInteger` (OpenDUNE `src/ini.c:14`).
///
/// Sections are `[Name]` at a line start; keys are `key=value`. Section names and keys are
/// case-insensitive; values run to the end of the line and are trimmed; there is no comment syntax.
/// Multi-value fields are returned raw and split by callers (on `,` / CR / LF). See
/// `Documentation/Formats/Ini.md`.
public struct Ini {
    private let orderedSections: [(name: String, entries: [(key: String, value: String)])]

    public init(_ data: Data) {
        self.init(text: String(data: data, encoding: .isoLatin1) ?? "")
    }

    public init(text: String) {
        var sections: [(name: String, entries: [(key: String, value: String)])] = []
        var current = -1

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let name = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
                sections.append((name, []))
                current = sections.count - 1
            } else if current >= 0, let equals = line.firstIndex(of: "=") {
                let key = line[line.startIndex ..< equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                sections[current].entries.append((key, value))
            }
        }
        self.orderedSections = sections
    }

    public var sectionNames: [String] { orderedSections.map(\.name) }

    public func keys(section: String) -> [String] {
        entries(section)?.map(\.key) ?? []
    }

    public func string(section: String, key: String, default defaultValue: String? = nil) -> String? {
        guard
            let match = entries(section)?.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })
        else {
            return defaultValue
        }

        return match.value
    }

    public func integer(section: String, key: String, default defaultValue: Int = 0) -> Int {
        guard let value = string(section: section, key: key) else { return defaultValue }

        return Ini.atoi(value)
    }

    private func entries(_ section: String) -> [(key: String, value: String)]? {
        orderedSections.first { $0.name.caseInsensitiveCompare(section) == .orderedSame }?.entries
    }

    /// C `atoi` semantics: optional leading whitespace and sign, decimal digits until a non-digit,
    /// 0 on garbage.
    static func atoi(_ string: String) -> Int {
        var characters = Substring(string).drop { $0 == " " || $0 == "\t" }
        var sign = 1
        if let first = characters.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            characters = characters.dropFirst()
        }

        var value = 0
        var sawDigit = false
        for character in characters {
            guard character.isASCII, let digit = character.wholeNumberValue, character.isNumber else { break }

            value = value * 10 + digit
            sawDigit = true
        }
        return sawDigit ? sign * value : 0
    }
}
