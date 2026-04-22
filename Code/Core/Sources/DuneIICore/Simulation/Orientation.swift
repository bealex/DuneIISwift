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

    /// Per-octant sprite-index offset + horizontal flip flag for
    /// DISPLAYMODE_UNIT / DISPLAYMODE_ROCKET. Five distinct frames
    /// (N, NE, E, SE, S); west-side facings mirror east-side.
    /// Mirrors `values_32A4` at `src/gui/viewport.c:334`.
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

    /// Per-octant sprite-bucket + horizontal flip flag for
    /// DISPLAYMODE_INFANTRY_3_FRAMES / DISPLAYMODE_INFANTRY_4_FRAMES.
    /// Only **three** direction buckets (N=0, side=1, S=2). NE/E/SE
    /// share the "side" bucket with no flip; SW/W/NW share it mirrored.
    /// Port of `values_32C4` at `src/gui/viewport.c:496`.
    public static let infantryBucket: [(bucket: UInt8, flipHorizontal: Bool)] = [
        (0, false),   // N
        (1, false),   // NE — reuse side bucket
        (1, false),   // E
        (1, false),   // SE
        (2, false),   // S
        (1, true),    // SW — mirror of side
        (1, true),    // W
        (1, true)     // NW
    ]

    /// 3-frame infantry walk-cycle phase, indexed by `spriteOffset & 3`.
    /// Walks out-and-back through {0, 1, 0, 2}: two legs swap and a
    /// stand pose. Port of `values_334A` at `src/gui/viewport.c:512`.
    public static let infantry3FramePhase: [UInt8] = [0, 1, 0, 2]
}
