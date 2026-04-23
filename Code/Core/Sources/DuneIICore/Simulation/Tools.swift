import Foundation

extension Simulation {
    /// Miscellaneous utility ports from OpenDUNE's `src/tools.c`.
    ///
    /// Scope note: `Tools_Random_*` already lives in `Core.RNG`; this
    /// namespace is reserved for the non-RNG helpers that other sim code
    /// and the tick-parity harness need.
    public enum Tools {

        /// Port of OpenDUNE `Tools_AdjustToGameSpeed`
        /// (`src/tools.c:20`).
        ///
        /// Scales a "normal" (gameSpeed = 2) value down or up depending
        /// on the current `gameSpeed` setting (0..4, where 2 is the
        /// canonical baseline). At `gameSpeed == 2` — and for any
        /// out-of-range value — the function is the identity and returns
        /// `normal` unchanged; this is how our default scheduler wires
        /// stay bit-identical to the old pre-port code.
        ///
        /// Clamp rule (also from the C): `maximum` caps at `normal * 2`
        /// and `minimum` caps at `normal / 2` before the switch, so the
        /// caller can pass wide outer bounds without the function
        /// overshooting.
        ///
        /// `inverseSpeed` lets timer code pass its "higher number =
        /// slower" semantics through the same table: the switch maps
        /// `gameSpeed` to `4 - gameSpeed` first.
        ///
        /// Tick-parity note: `Unit_SetSpeed` (`src/unit.c:1902`) and
        /// `Unit_MovementTick` (`src/unit.c:98`) both call this with
        /// `minimum=1, maximum=255, inverseSpeed=false`. At the default
        /// `gameSpeed=2` every call is identity, so porting this does
        /// not regress any existing test. The machinery is present so
        /// the tick-parity harness can drive OpenDUNE at non-default
        /// speeds and still match field-for-field.
        @inlinable
        public static func adjustToGameSpeed(
            normal: UInt16,
            minimum: UInt16,
            maximum: UInt16,
            inverseSpeed: Bool,
            gameSpeed: UInt8
        ) -> UInt16 {
            if gameSpeed == 2 { return normal }
            if gameSpeed > 4 { return normal }

            var minimum = minimum
            var maximum = maximum
            if maximum > normal &* 2 { maximum = normal &* 2 }
            if minimum < normal / 2 { minimum = normal / 2 }

            let bucket: UInt8 = inverseSpeed ? (4 &- gameSpeed) : gameSpeed

            switch bucket {
            case 0: return minimum
            case 1: return normal &- (normal &- minimum) / 2
            case 3: return normal &+ (maximum &- normal) / 2
            case 4: return maximum
            default: return normal
            }
        }
    }
}
