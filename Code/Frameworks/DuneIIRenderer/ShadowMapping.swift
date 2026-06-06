import DuneIIFormats

/// The air-unit **shadow** colour lookup — OpenDUNE's `g_paletteMapping1`.
///
/// Built once at init from the base palette (`opendune.c:959`):
/// `GUI_Palette_CreateMapping(g_palette1, g_paletteMapping1, 0xC, 0x55)`, then the three fixed overrides
/// `[0xFF] = 0xFF`, `[0xDF] = 0xDF`, `[0xEF] = 0xEF` (`opendune.c:963-965`). For every palette index it
/// finds the nearest palette colour to that colour blended ~33% (`0x55 / 2` over `128`) toward the dark
/// reference colour `0xC` — i.e. a "darken toward shadow" remap. A winger's shadow (`viewport.c:737`) is
/// drawn `REMAP | BLUR` with this table, which (`gui.c:1303`) for each opaque silhouette pixel remaps the
/// **background** pixel underneath through the LUT — darkening the terrain / building beneath the aircraft.
/// OpenDUNE never rebuilds this table on a palette cycle, so we derive it once from the base palette.
public enum ShadowMapping {
    /// `GUI_Palette_CreateMapping`'s dark reference colour (`0xC`) and blend intensity (`0x55`).
    public static let reference = 0xC
    public static let intensity = 0x55
    /// The indices kept unchanged after the mapping is built (`opendune.c:963-965`).
    public static let fixed = [ 0xFF, 0xDF, 0xEF ]

    /// The 256-entry darkening LUT for `palette` — `out[index]` is the palette index whose colour is
    /// closest to `palette[index]` blended toward `palette[reference]`. Index 0 maps to 0 (the shadow draw
    /// reads the background, never a 0 source pixel, but `GUI_Palette_CreateMapping` sets `colours[0] = 0`).
    /// Pure; no CoreGraphics. A degenerate (< 256 colour) palette returns the identity table.
    public static func table(_ palette: Palette) -> [UInt8] {
        let c = palette.colors
        guard c.count >= 256 else { return (0 ... 255).map { UInt8($0) } }

        // Components are 6-bit (0...63); both the blend and the nearest search use them directly. The result
        // index mapping is scale-invariant, so working in 6-bit (not the 8-bit display expansion) is exact.
        let ref = c[reference]
        let half = intensity / 2  // 0x2A — `intensity / 2` in `GUI_Palette_CreateMapping`
        var out = [UInt8](repeating: 0, count: 256)

        for index in 1 ..< 256 {
            let src = c[index]
            // Blend `half/128` of the way from the source colour toward the reference (`opendune` names the
            // three components red/blue/green but uses them in storage order 0,1,2 — the distance is the same
            // regardless of labelling, so we use red/green/blue in order).
            let r = blend(Int(src.red), Int(ref.red), half)
            let g = blend(Int(src.green), Int(ref.green), half)
            let b = blend(Int(src.blue), Int(ref.blue), half)

            var best = reference
            var bestSum = Int.max
            for i in 1 ..< 256 {
                let ci = c[i]
                let dr = Int(ci.red) - r, dg = Int(ci.green) - g, db = Int(ci.blue) - b
                let sum = dr * dr + dg * dg + db * db
                if sum > bestSum { continue }
                if i != reference, i == index { continue }  // a colour never maps to itself except `reference`

                bestSum = sum
                best = i
            }
            out[index] = UInt8(best)
        }
        for f in fixed where f < 256 { out[f] = UInt8(f) }
        return out
    }

    private static func blend(_ value: Int, _ reference: Int, _ half: Int) -> Int {
        value - (((value - reference) * half) >> 7)
    }
}
