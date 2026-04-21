import Foundation

extension Formats {
    public enum Save {
        /// IFF-style chunk container for `_SAVE00?.DAT`.
        ///
        /// Shape: `FORM <size:u32be> SCEN { <tag:4cc> <len:u32be> <body:len> <pad?> }...`
        /// where the pad byte is present iff `len` is odd. `SCEN` is the IFF
        /// form-type tag — no length, no body.
        ///
        /// This type only walks the container and indexes chunks by tag.
        /// Per-chunk decoders (`INFO`, `PLYR`, `UNIT`, …) layer on top.
        public struct Container: Sendable, Equatable {
            /// Tags in file order. `MAP ` carries the trailing space verbatim.
            public let tags: [String]
            private let bodies: [String: Data]

            public enum DecodeError: Error, Equatable, Sendable {
                case truncated
                case notForm
                case notScen
                case chunkLengthPastEnd(tag: String, length: UInt32)
                case duplicateChunk(tag: String)
            }

            public init(tags: [String], bodies: [String: Data]) {
                self.tags = tags
                self.bodies = bodies
            }

            public func chunk(named tag: String) -> Data? {
                bodies[tag]
            }

            public var isModernVersion: Bool { version == 0x0290 }

            /// Little-endian `u16` at the head of `INFO`. Returns `nil` when
            /// `INFO` is absent or shorter than 2 bytes.
            public var version: UInt16? {
                guard let info = bodies["INFO"], info.count >= 2 else { return nil }
                let base = info.startIndex
                return UInt16(info[base]) | (UInt16(info[base + 1]) << 8)
            }

            public static func decode(_ data: Data) throws -> Container {
                guard data.count >= 12 else { throw DecodeError.truncated }
                let base = data.startIndex
                guard readFourCC(data, at: base) == "FORM" else { throw DecodeError.notForm }
                // Skip the outer size field — we trust the buffer length instead.
                guard readFourCC(data, at: base + 8) == "SCEN" else { throw DecodeError.notScen }

                var tags: [String] = []
                var bodies: [String: Data] = [:]
                var cursor = base + 12
                let end = data.endIndex

                while cursor + 8 <= end {
                    let tag = readFourCC(data, at: cursor)
                    let length = readU32BE(data, at: cursor + 4)
                    let bodyStart = cursor + 8
                    guard let bodyEnd = bodyStart.addingReportingOverflow(Int(length)).0 as Int?,
                          bodyEnd <= end else {
                        throw DecodeError.chunkLengthPastEnd(tag: tag, length: length)
                    }
                    if bodies[tag] != nil { throw DecodeError.duplicateChunk(tag: tag) }
                    let body = data.subdata(in: bodyStart..<bodyEnd)
                    tags.append(tag)
                    bodies[tag] = body
                    cursor = bodyEnd + (Int(length) & 1)
                }

                return Container(tags: tags, bodies: bodies)
            }
        }

        // MARK: - Helpers

        private static func readFourCC(_ data: Data, at offset: Int) -> String {
            let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }

        private static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }
    }
}
