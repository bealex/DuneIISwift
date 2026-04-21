import Foundation

/// Bit-for-bit Swift transcriptions of OpenDUNE's two PRNGs. Save-file
/// parity and AI reproducibility both depend on these producing the
/// same sequence the C original does.
public enum RNG {
    /// `Tools_Random_256` — produces one `UInt8` per call. Port of
    /// `src/tools.c::Tools_Random_256` with identical wrap-around semantics.
    public struct ToolsRandom256: Sendable {
        public var a: UInt8
        public var b: UInt8
        public var c: UInt8
        public var d: UInt8

        public init(seed: UInt32) {
            self.a = UInt8(truncatingIfNeeded: seed)
            self.b = UInt8(truncatingIfNeeded: seed >> 8)
            self.c = UInt8(truncatingIfNeeded: seed >> 16)
            self.d = UInt8(truncatingIfNeeded: seed >> 24)
        }

        public mutating func next() -> UInt8 {
            var val16 = (UInt16(b) << 8) | UInt16(c)
            var val8 = UInt8(truncatingIfNeeded: ((val16 ^ 0x8000) >> 15) & 1)
            val16 = (val16 << 1) | (UInt16(a >> 1) & 1)
            val8 = (a >> 2) &- a &- val8
            a = (val8 << 7) | (a >> 1)
            b = UInt8(truncatingIfNeeded: val16 >> 8)
            c = UInt8(truncatingIfNeeded: val16 & 0xFF)
            return a ^ b
        }
    }

    /// Borland C/C++ style LCG (`a = 0x015A4E35`, `c = 1`). Port of
    /// `src/tools.c::Tools_RandomLCG` + `Tools_RandomLCG_Range`.
    public struct BorlandLCG: Sendable {
        public var state: UInt32

        public init(seed: UInt16) {
            self.state = UInt32(seed)
        }

        public mutating func next() -> Int16 {
            state = 0x015A4E35 &* state &+ 1
            return Int16(bitPattern: UInt16(truncatingIfNeeded: (state >> 16) & 0x7FFF))
        }

        public mutating func range(_ minValue: UInt16, _ maxValue: UInt16) -> UInt16 {
            var lo = minValue
            var hi = maxValue
            if lo > hi { swap(&lo, &hi) }
            let span = Int32(hi) - Int32(lo) + 1
            while true {
                let raw = Int32(next())
                let value = UInt16(raw * span / 0x8000) &+ lo
                if value <= hi { return value }
            }
        }
    }
}
