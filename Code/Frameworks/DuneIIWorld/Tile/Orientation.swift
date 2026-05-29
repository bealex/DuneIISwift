/// Conversions from Dune II's fine 0...255 orientation to the coarser 8- and 16-step facings used for
/// sprite selection and movement. Bit-exact ports of `Orientation_Orientation256ToOrientation8` and
/// `...16` (OpenDUNE `src/tile.c:433` / `:443`). The `+16`/`+8` bias rounds to the nearest step.
///
/// Verified against an OpenDUNE golden dump — see `Documentation/Algorithms/Tile.md`.
public enum Orientation {
    /// 0...255 → 0...7.
    public static func to8(_ orientation: UInt8) -> UInt8 {
        UInt8(((Int(orientation) + 16) / 32) & 0x7)
    }

    /// 0...255 → 0...15.
    public static func to16(_ orientation: UInt8) -> UInt8 {
        UInt8(((Int(orientation) + 8) / 16) & 0xF)
    }
}
