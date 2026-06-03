import Foundation

/// Reader for Westwood PAK archives (the containers under the original install). A PAK is a table of
/// (uint32 LE data offset, NUL-terminated name) entries terminated by a zero offset, followed by the
/// file data the offsets point at; an entry's size is the next entry's offset minus its own (the last
/// entry runs to end-of-file). Ported from the PAK layout in OpenDUNE `src/file.c` /
/// `src/tools/extractpak.c`. See `Documentation/Formats/Pak.md`.
public enum Pak {
    public enum DecodeError: Error, Equatable {
        case truncated
    }

    public struct Archive {
        public struct Entry: Equatable {
            public let name: String
            public let offset: Int
            public let size: Int
        }

        public let entries: [Entry]
        private let bytes: [UInt8]

        public init(_ data: Data) throws {
            let bytes = [ UInt8 ](data)
            let total = bytes.count
            var entries: [Entry] = []
            var cursor = 0

            guard total >= 4 else { throw DecodeError.truncated }

            var offset = bytes.u32LE(at: cursor)
            cursor += 4

            while offset != 0 {
                var nameBytes: [UInt8] = []
                while true {
                    guard cursor < total else { throw DecodeError.truncated }

                    let character = bytes[cursor]
                    cursor += 1
                    if character == 0 { break }

                    nameBytes.append(character)
                }

                guard cursor + 4 <= total else { throw DecodeError.truncated }

                let next = bytes.u32LE(at: cursor)
                cursor += 4

                let size = (next != 0 ? next : total) - offset
                guard size >= 0, offset >= 0, offset + size <= total else { throw DecodeError.truncated }

                let name = String(bytes: nameBytes, encoding: .ascii) ?? ""
                entries.append(Entry(name: name, offset: offset, size: size))
                offset = next
            }

            self.bytes = bytes
            self.entries = entries
        }

        /// The raw bytes of an entry.
        public func data(_ entry: Entry) -> Data {
            Data(bytes[entry.offset ..< entry.offset + entry.size])
        }

        /// Look up an entry by name (case-insensitive, matching the original file layer).
        public func entry(named name: String) -> Entry? {
            entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        /// The raw bytes of the named entry, if present.
        public func data(named name: String) -> Data? {
            entry(named: name).map(data)
        }
    }
}
