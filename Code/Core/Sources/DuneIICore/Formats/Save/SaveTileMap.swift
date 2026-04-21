import Foundation

extension Formats.Save {
    /// Body of the `MAP ` chunk (trailing space). Sparse list of `(cellIndex,
    /// packedTile)` overrides against the map-seed-generated baseline.
    ///
    /// Wire layout: `Documentation/Formats/SAVE.md` §11.
    /// Reference: OpenDUNE `src/saveload/map.c` (`fread_tile` / `Map_Load`).
    public struct TileMap: Sendable, Equatable {
        public let entries: [Entry]

        public static let recordSize = 6
        public static let cellCap = 0x1000 // 64 × 64

        public enum DecodeError: Error, Equatable, Sendable {
            case misalignedBody(length: Int)
            case cellIndexOutOfRange(UInt16)
        }

        public struct Entry: Sendable, Equatable {
            public let cellIndex: UInt16
            public let tile: Tile
        }

        /// Unpacked 4-byte tile record. Fields mirror OpenDUNE's bit-packed
        /// `Tile` struct in `src/map.h`.
        public struct Tile: Sendable, Equatable {
            /// 9 bits; range `0…511`.
            public let groundTileID: UInt16
            /// 7 bits; range `0…127`.
            public let overlayTileID: UInt8
            /// 3 bits; range `0…7`.
            public let houseID: UInt8
            public let isUnveiled: Bool
            public let hasUnit: Bool
            public let hasStructure: Bool
            public let hasAnimation: Bool
            public let hasExplosion: Bool
            /// Pool-index-plus-one reference; `0` = none, `n` = Structure/Unit
            /// at pool index `n - 1`. Off-by-one inherited from the original.
            public let tileIndex: UInt8
        }

        public static func decode(_ body: Data) throws -> TileMap {
            if body.count % recordSize != 0 {
                throw DecodeError.misalignedBody(length: body.count)
            }
            let count = body.count / recordSize
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            var cursor = body.startIndex
            for _ in 0..<count {
                let cellIndex = UInt16(body[cursor]) | (UInt16(body[cursor + 1]) << 8)
                if cellIndex >= cellCap {
                    throw DecodeError.cellIndexOutOfRange(cellIndex)
                }
                let b0 = body[cursor + 2]
                let b1 = body[cursor + 3]
                let b2 = body[cursor + 4]
                let b3 = body[cursor + 5]
                let tile = Tile(
                    groundTileID: UInt16(b0) | (UInt16(b1 & 0x01) << 8),
                    overlayTileID: b1 >> 1,
                    houseID: b2 & 0x07,
                    isUnveiled: b2 & 0x08 != 0,
                    hasUnit: b2 & 0x10 != 0,
                    hasStructure: b2 & 0x20 != 0,
                    hasAnimation: b2 & 0x40 != 0,
                    hasExplosion: b2 & 0x80 != 0,
                    tileIndex: b3
                )
                entries.append(Entry(cellIndex: cellIndex, tile: tile))
                cursor += recordSize
            }
            return TileMap(entries: entries)
        }
    }
}
