/// The kind of object an encoded 16-bit index refers to. Ported from OpenDUNE's `IndexType`
/// (`src/tools.h:9`): the top two bits of an encoded index carry the type.
public enum IndexType: Int, Sendable {
    case none = 0
    case tile = 1
    case unit = 2
    case structure = 3
}

public extension Tools {
    /// `Tools_Index_GetType` (`tools.c:48`): the type tag in the top two bits of an encoded index.
    static func indexType(_ encoded: UInt16) -> IndexType {
        return switch encoded & 0xC000 {
            case 0x4000: .unit
            case 0x8000: .structure
            case 0xC000: .tile
            default: .none
        }
    }

    /// `Tools_Index_Decode` (`tools.c:64`): the bare index/packed-tile carried by an encoded index.
    /// For a tile, the X/Y are stored interleaved-odd and are repacked; otherwise the low 14 bits.
    static func indexDecode(_ encoded: UInt16) -> UInt16 {
        if indexType(encoded) == .tile {
            return Tile32.packXY(x: (encoded >> 1) & 0x3F, y: (encoded >> 8) & 0x3F)
        }
        return encoded & 0x3FFF
    }

    // Tools_Index_Encode (and Tools_Index_IsValid / GetUnit / GetStructure / GetTile / GetObject) need
    // the object pools — they arrive with the World model.
}
