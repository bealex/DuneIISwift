import DuneIIFormats
import Foundation

/// The six houses of Dune II, in the engine's `houseID` order. House 0 (Harkonnen) is the base
/// palette (no shift); other houses shift the house-color block by `id << 4`.
public enum House: Int, CaseIterable, Sendable {
    case harkonnen = 0
    case atreides = 1
    case ordos = 2
    case fremen = 3
    case sardaukar = 4
    case mercenary = 5

    public var displayName: String {
        switch self {
            case .harkonnen: return "Harkonnen"
            case .atreides: return "Atreides"
            case .ordos: return "Ordos"
            case .fremen: return "Fremen"
            case .sardaukar: return "Sardaukar"
            case .mercenary: return "Mercenary"
        }
    }
}

/// House color remapping of 8-bit palette indices, ported faithfully from OpenDUNE (the 1.07 path).
public enum HouseRemap {
    /// Sprite (SHP) recolor — `GUI_Widget_Viewport_GetSprite_HousePalette` (`gui/viewport.c:300`):
    /// palette-lookup entries in `0x90...0x98` shift by `house.rawValue << 4`. Only applied to frames
    /// that carried a lookup table (`Shp.Frame.hasLookup`).
    public static func sprite(_ index: UInt8, house: House) -> UInt8 {
        guard house != .harkonnen, index >= 0x90, index <= 0x98 else { return index }

        return UInt8((Int(index) + (house.rawValue << 4)) & 0xFF)
    }

    /// Tile (ICN) recolor — `GFX_DrawTile` (`gfx.c:224`): tile-palette entries with high nibble `0x90`
    /// (`0x90...0x9F`) shift by `house.rawValue << 4`. (The enhanced `<= 0x96` clamp is not applied —
    /// this is the 1.07 behavior.)
    public static func tile(_ index: UInt8, house: House) -> UInt8 {
        guard house != .harkonnen, (index & 0xF0) == 0x90 else { return index }

        return UInt8((Int(index) + (house.rawValue << 4)) & 0xFF)
    }
}
