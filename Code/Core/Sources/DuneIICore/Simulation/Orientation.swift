import Foundation

/// Orientation helpers ported from `src/tile.c:433` +
/// `src/gui/viewport.c:334` (`values_32A4` frame-index / flip table).
public enum Orientation {
    /// `Orientation_Orientation256ToOrientation8(o) = ((o + 16) / 32) & 7`.
    /// Maps a signed or unsigned 8-bit orientation (0..255) into one of
    /// 8 octants (0..7).
    public static func to8(_ raw256: Int8) -> UInt8 {
        let o = UInt8(bitPattern: raw256)
        return UInt8((UInt16(o) &+ 16) / 32) & 0x7
    }

    /// Per-octant sprite-index offset + horizontal flip flag. Only 5
    /// distinct frames cover the 8 directions; east-side frames are
    /// re-used and mirrored for west-side facings. Mirrors
    /// `values_32A4` at `src/gui/viewport.c:334`.
    public static let octantFrame: [(offset: UInt8, flipHorizontal: Bool)] = [
        (0, false),   // N
        (1, false),   // NE
        (2, false),   // E
        (3, false),   // SE
        (4, false),   // S
        (3, true),    // SW — mirror of SE
        (2, true),    // W  — mirror of E
        (1, true)     // NW — mirror of NE
    ]
}
