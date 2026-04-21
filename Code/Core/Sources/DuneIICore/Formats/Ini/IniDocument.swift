import Foundation

extension Formats {
    public enum Ini {
        public struct Entry: Sendable, Hashable {
            public let key: String
            public let value: String
        }

        public struct Section: Sendable {
            public let name: String
            /// Entries in the order they appeared on disk. Real scenarios
            /// rely on `[UNITS]` / `[STRUCTURES]` being iterated in file
            /// order to place entities deterministically.
            public let entries: [Entry]

            /// Case-insensitive key lookup. When a key appears more than
            /// once, the **last** assignment wins — matching OpenDUNE's
            /// "loop until match, return current match" behavior.
            public func value(forKey key: String) -> String? {
                let lower = key.lowercased()
                return entries.last(where: { $0.key.lowercased() == lower })?.value
            }

            public func integerValue(forKey key: String) -> Int? {
                guard let raw = value(forKey: key), !raw.isEmpty else { return nil }
                return Int(raw.trimmingCharacters(in: .whitespaces))
            }

            /// Parses a comma-separated list of integers. Any element that
            /// fails to parse makes the whole list `nil`.
            public func integerListValue(forKey key: String) -> [Int]? {
                guard let raw = value(forKey: key) else { return nil }
                let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                var out: [Int] = []
                out.reserveCapacity(parts.count)
                for part in parts {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    guard let n = Int(trimmed) else { return nil }
                    out.append(n)
                }
                return out
            }
        }

        public struct Document: Sendable {
            public let sections: [Section]

            /// Case-insensitive section lookup.
            public subscript(name: String) -> Section? {
                let lower = name.lowercased()
                return sections.first(where: { $0.name.lowercased() == lower })
            }

            public static func decode(_ data: Data) throws -> Document {
                guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                    throw DecodeError.notText
                }

                var sections: [Section] = []
                var currentName: String? = nil
                var currentEntries: [Entry] = []

                // Line-based walk. `components(separatedBy: .newlines)` handles
                // CR/LF, bare LF, and bare CR uniformly.
                let lines = text.components(separatedBy: .newlines)
                for rawLine in lines {
                    let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

                    if trimmed.isEmpty { continue }
                    if trimmed.hasPrefix(";") { continue }

                    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                        // Close out the prior section, if any.
                        if let name = currentName {
                            sections.append(Section(name: name, entries: currentEntries))
                        }
                        currentName = String(trimmed.dropFirst().dropLast())
                            .trimmingCharacters(in: .whitespaces)
                        currentEntries = []
                        continue
                    }

                    // A key=value line. Ignore lines outside any section.
                    guard currentName != nil else { continue }
                    guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                    let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
                    let value = trimmed[trimmed.index(after: eqIndex)...]
                        .trimmingCharacters(in: .whitespaces)
                    if key.isEmpty { continue }
                    currentEntries.append(Entry(key: String(key), value: String(value)))
                }

                if let name = currentName {
                    sections.append(Section(name: name, entries: currentEntries))
                }
                return Document(sections: sections)
            }
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case notText
        }
    }
}
