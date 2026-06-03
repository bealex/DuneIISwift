import Foundation

/// Reader for the IFF/FORM chunk container used by ICN tilesets, EMC scripts, and savegames.
///
/// Layout: `"FORM"` + uint32 BE total length + a 4CC form type + chunks. Each chunk is a 4CC + uint32 BE
/// length + payload, padded to an even length. Ported from OpenDUNE's `ChunkFile_*` (`src/file.c:1039`)
/// and the savegame reader `Load_FindChunk` (`src/load.c:30`). See `Documentation/Formats/Iff.md`.
public enum Iff {
    public enum DecodeError: Error, Equatable {
        case notForm
        case truncated
    }

    public struct Reader {
        public struct Chunk: Equatable {
            public let id: String
            public let range: Range<Int>
        }

        public let formType: String
        public let chunks: [Chunk]
        private let bytes: [UInt8]

        public init(_ data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count >= 12, bytes.fourCC(at: 0) == "FORM" else { throw DecodeError.notForm }

            let formType = bytes.fourCC(at: 8)
            var chunks: [Chunk] = []
            var cursor = 12
            while cursor + 8 <= bytes.count {
                // Tolerate a stray zero dword between chunks (ChunkFile_* does the same).
                if bytes.u32BE(at: cursor) == 0 {
                    cursor += 4
                    continue
                }

                let id = bytes.fourCC(at: cursor)
                let length = bytes.u32BE(at: cursor + 4)
                let start = cursor + 8
                guard start + length <= bytes.count else { throw DecodeError.truncated }

                chunks.append(Chunk(id: id, range: start ..< start + length))
                cursor = start + length + (length & 1)
            }

            self.bytes = bytes
            self.formType = formType
            self.chunks = chunks
        }

        /// The payload bytes of the first chunk with this 4CC (e.g. `"SSET"`, `"TEXT"`, `"MAP "`).
        public func chunk(_ id: String) -> Data? {
            guard let match = chunks.first(where: { $0.id == id }) else { return nil }

            return Data(bytes[match.range])
        }
    }
}
