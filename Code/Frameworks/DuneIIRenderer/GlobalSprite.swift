/// One of the three concatenated unit sprite sheets and a frame within it. The engine addresses unit /
/// effect sprites by a single **global** index across all three; the renderer maps it back to a sheet +
/// local frame.
public enum UnitSpriteSheet: String, Sendable, CaseIterable {
    case units2 = "UNITS2.SHP"
    case units1 = "UNITS1.SHP"
    case units  = "UNITS.SHP"

    /// The on-disk SHP file name (the key the asset stores use).
    public var fileName: String { rawValue }
}

/// The `Sprites_Init` (`src/sprites.c`) load-order mapping: a global unit/effect sprite index resolves
/// to one of the three unit SHP sheets plus a local frame, by the cumulative bases the original loads
/// them at — UNITS2 first (base 111), then UNITS1 (151), then UNITS (238). This is the single canonical
/// home of that mapping (previously copy-pasted in the verification apps).
public enum GlobalSprite {
    /// Map a global unit/effect sprite index to its sheet + local frame, or `nil` if below the unit base.
    public static func unit(_ index: Int) -> (sheet: UnitSpriteSheet, frame: Int)? {
        if index >= 238 { return (.units, index - 238) }
        if index >= 151 { return (.units1, index - 151) }
        if index >= 111 { return (.units2, index - 111) }
        return nil
    }
}
