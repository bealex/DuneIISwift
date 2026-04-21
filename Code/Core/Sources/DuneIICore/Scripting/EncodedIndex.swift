import Foundation

extension Scripting {
    /// Port of OpenDUNE's `Tools_Index_Encode` / `Tools_Index_GetType` / ...
    /// The top two bits of the `uint16` pick `Kind`; the lower bits carry
    /// the pool index (for unit/structure) or a packed tile (for tile).
    ///
    /// Validity (`Tools_Index_IsValid`) depends on live pool state (`used`,
    /// `allocated`) and therefore lives on `Scripting.Host`, not here.
    public struct EncodedIndex: Sendable, Equatable {
        public let raw: UInt16

        public enum Kind: Sendable, Equatable {
            case none
            case tile
            case unit
            case structure
        }

        public init(raw: UInt16) {
            self.raw = raw
        }

        public var kind: Kind {
            if raw == 0 { return .none }
            switch raw & 0xC000 {
            case 0x4000: return .unit
            case 0x8000: return .structure
            case 0xC000: return .tile
            default:     return .none
            }
        }

        /// Pool index for `.unit` / `.structure`; packed-tile position for
        /// `.tile`; `0` for `.none`.
        public var decoded: UInt16 {
            switch kind {
            case .tile:
                let x = (raw >> 1) & 0x3F
                let y = (raw >> 8) & 0x3F
                return (y << 6) | x // Tile_PackXY(x, y) == y*64 + x
            case .unit, .structure:
                return raw & 0x3FFF
            case .none:
                return 0
            }
        }

        public static func unit(_ index: UInt16) -> EncodedIndex {
            EncodedIndex(raw: index | 0x4000)
        }

        public static func structure(_ index: UInt16) -> EncodedIndex {
            EncodedIndex(raw: index | 0x8000)
        }

        /// Port of `Tools_Index_Encode(packed, IT_TILE)` — the bit
        /// layout uses `(x << 1) + 1` / `(y << 1) + 1` so odd-bit
        /// round-tripping is stable through `Tools_Index_Decode`.
        /// Input: 12-bit packed tile (y*64 + x).
        public static func tile(packed: UInt16) -> EncodedIndex {
            let x = packed & 0x3F
            let y = (packed >> 6) & 0x3F
            let raw: UInt16 = 0xC000 | (((x &<< 1) &+ 1)) | (((y &<< 1) &+ 1) &<< 7)
            return EncodedIndex(raw: raw)
        }
    }
}
