/// CHOAM — the starport price roll. A port of `GUI_FactoryWindow_CalculateStarportPrice`
/// (`src/gui/gui.c:2726`): each in-stock unit is priced through CHOAM when the starport window opens, at a
/// randomised 40 %…160 % of the unit's base build cost (capped at 999). See `Documentation/Algorithms/StarportPrice.md`.
public extension GameState {
    /// The CHOAM price for a unit whose base cost is `buildCredits`. Draws **two** `RandomLCG` values (so it
    /// is `mutating`); opening the starport list perturbs the LCG stream exactly as the original does.
    ///
    /// `price = (c/10)*4 + (c/10)*(RandomLCG_Range(0,6) + RandomLCG_Range(0,6))`, then `min(price, 999)`.
    mutating func starportPrice(buildCredits: UInt16) -> UInt16 {
        let tenth = UInt32(buildCredits / 10)
        let roll = UInt32(randomLCG.range(0, 6)) + UInt32(randomLCG.range(0, 6))
        let price = tenth * 4 + tenth * roll
        return UInt16(min(price, 999))
    }
}
