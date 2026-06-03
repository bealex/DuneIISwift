/// Native helpers ported from OpenDUNE `src/tools.c`. Pure functions; any state they read in the
/// original (the game-speed setting, the object pools) is passed in or deferred to `GameState`.
public enum Tools {
    /// `Tools_AdjustToGameSpeed` (`tools.c:20`): scale a "normal" tick count between `minimum` and
    /// `maximum` for the current game speed (0 slowest … 4 fastest; 2 = normal/unscaled). `inverseSpeed`
    /// flips the scale (for things that should get *slower* as the game speeds up). In OpenDUNE the speed
    /// is the `g_gameConfig.gameSpeed` global; here it is passed in (it will live in `GameState`).
    ///
    /// Verified against an OpenDUNE golden dump — see `Documentation/Algorithms/Tools.md`.
    public static func adjustToGameSpeed(
        normal: UInt16,
        minimum: UInt16,
        maximum: UInt16,
        inverseSpeed: Bool,
        gameSpeed: UInt16
    ) -> UInt16 {
        if gameSpeed == 2 { return normal }
        if gameSpeed > 4 { return normal }

        let n = Int(normal)
        var maxValue = Int(maximum)
        var minValue = Int(minimum)
        // The original truncates these clamps back to uint16 before reuse.
        if maxValue > n * 2 { maxValue = Int(UInt16(truncatingIfNeeded: n * 2)) }
        if minValue < n / 2 { minValue = n / 2 }

        var speed = Int(gameSpeed)
        if inverseSpeed { speed = 4 - speed }

        return switch speed {
            case 0: UInt16(truncatingIfNeeded: minValue)
            case 1: UInt16(truncatingIfNeeded: n - (n - minValue) / 2)
            case 3: UInt16(truncatingIfNeeded: n + (maxValue - n) / 2)
            case 4: UInt16(truncatingIfNeeded: maxValue)
            default: normal
        }
    }
}
