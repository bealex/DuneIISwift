import Foundation

extension Formats {
    public enum Pak {
        public struct Entry: Sendable, Hashable {
            public let name: String
            public let range: Range<Int>

            public var size: Int { range.count }
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case headerTruncated
            case nameTooLong(Int)
            case nameNotAscii
            case nonMonotonicOffset(previous: UInt32, current: UInt32)
            case offsetPastEnd(UInt32)
            case missingTerminator
        }

        public struct Archive: Sendable {
            public let data: Data
            public let entries: [Entry]
            private let index: [String: Int]

            public init(data: Data) throws {
                self.data = data
                self.entries = try Self.parseIndex(in: data)
                var index: [String: Int] = [:]
                index.reserveCapacity(entries.count)
                for (i, entry) in entries.enumerated() {
                    index[entry.name.uppercased()] = i
                }
                self.index = index
            }

            public init(contentsOf url: URL) throws {
                let mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
                try self.init(data: mapped)
            }

            public func entry(named name: String) -> Entry? {
                index[name.uppercased()].map { entries[$0] }
            }

            public func body(for entry: Entry) -> Data {
                data.subdata(in: entry.range)
            }

            public func body(named name: String) -> Data? {
                entry(named: name).map(body(for:))
            }

            private static func parseIndex(in data: Data) throws -> [Entry] {
                let totalSize = data.count
                guard totalSize >= 4 else { throw DecodeError.headerTruncated }

                var cursor = 0
                var rawEntries: [(name: String, offset: UInt32)] = []

                // Walk header: sequence of (u32 offset, NUL-terminated ASCII name),
                // terminated by a zero u32.
                while true {
                    let offset = try readU32LE(data, at: cursor)
                    cursor += 4
                    if offset == 0 { break }

                    // Name extends to the next NUL. We match the DOS 8.3 + NUL limit
                    // (13 bytes including terminator) used by all original PAKs;
                    // reject anything longer as corruption.
                    let maxName = 13
                    var nameBytes: [UInt8] = []
                    nameBytes.reserveCapacity(12)
                    var nameConsumed = 0
                    while nameConsumed < maxName {
                        guard cursor < totalSize else { throw DecodeError.headerTruncated }
                        let byte = data[data.startIndex + cursor]
                        cursor += 1
                        nameConsumed += 1
                        if byte == 0 { break }
                        guard byte < 0x80 else { throw DecodeError.nameNotAscii }
                        nameBytes.append(byte)
                    }
                    if nameBytes.count == maxName {
                        throw DecodeError.nameTooLong(maxName)
                    }
                    guard let name = String(bytes: nameBytes, encoding: .ascii) else {
                        throw DecodeError.nameNotAscii
                    }
                    if let previous = rawEntries.last, offset <= previous.offset {
                        throw DecodeError.nonMonotonicOffset(previous: previous.offset, current: offset)
                    }
                    if Int(offset) > totalSize {
                        throw DecodeError.offsetPastEnd(offset)
                    }
                    rawEntries.append((name: name, offset: offset))
                }

                if rawEntries.isEmpty { return [] }

                // Bodies: each entry ends where the next begins; the last runs to EOF.
                var entries: [Entry] = []
                entries.reserveCapacity(rawEntries.count)
                for (i, raw) in rawEntries.enumerated() {
                    let start = Int(raw.offset)
                    let end = (i + 1 < rawEntries.count)
                        ? Int(rawEntries[i + 1].offset)
                        : totalSize
                    guard start <= end, end <= totalSize else {
                        throw DecodeError.offsetPastEnd(raw.offset)
                    }
                    entries.append(Entry(name: raw.name, range: start..<end))
                }
                return entries
            }

            private static func readU32LE(_ data: Data, at offset: Int) throws -> UInt32 {
                guard offset + 4 <= data.count else { throw DecodeError.headerTruncated }
                let base = data.startIndex + offset
                let b0 = UInt32(data[base])
                let b1 = UInt32(data[base + 1])
                let b2 = UInt32(data[base + 2])
                let b3 = UInt32(data[base + 3])
                return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            }
        }

        public enum Encoder {
            public static func encode(_ files: [(name: String, body: Data)]) throws -> Data {
                for file in files {
                    guard file.name.count <= 12 else { throw DecodeError.nameTooLong(file.name.count) }
                    guard file.name.allSatisfy({ $0.isASCII }) else { throw DecodeError.nameNotAscii }
                }
                var headerSize = 4 // terminator
                for file in files {
                    headerSize += 4 + file.name.utf8.count + 1
                }
                var out = Data()
                out.reserveCapacity(headerSize + files.reduce(0) { $0 + $1.body.count })
                var runningOffset = headerSize
                for file in files {
                    out.append(uint32LE: UInt32(runningOffset))
                    out.append(contentsOf: file.name.uppercased().utf8)
                    out.append(0)
                    runningOffset += file.body.count
                }
                out.append(uint32LE: 0)
                for file in files {
                    out.append(file.body)
                }
                return out
            }
        }
    }
}

extension Data {
    mutating fileprivate func append(uint32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

extension Formats.Pak.Archive: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries == rhs.entries && lhs.data == rhs.data
    }
}
