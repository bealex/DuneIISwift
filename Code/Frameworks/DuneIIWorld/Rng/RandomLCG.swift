/// Dune II's secondary random generator: the Borland C/C++ linear-congruential generator the original
/// was compiled with. A bit-exact port of `Tools_RandomLCG` / `Tools_RandomLCG_Range` (OpenDUNE
/// `src/tools.c:327` and `:341`) plus `Tools_RandomLCG_Seed` (`tools.c:319`). The scripts reach it via
/// `General_RandomRange`; `GameState` will own the live instance.
///
/// Verified bit-for-bit against an OpenDUNE golden dump (`Tests/WorldTests/Fixtures/rng-golden.jsonl`,
/// produced by `opendune --parity-golden`). See `Documentation/Algorithms/Rng.md`.
public struct RandomLCG: Sendable {
    private var state: UInt32

    public init(seed: UInt16 = 0) {
        state = UInt32(seed)
    }

    /// `Tools_RandomLCG_Seed`: the 32-bit state is seeded from a 16-bit value.
    public mutating func reseed(_ seed: UInt16) {
        state = UInt32(seed)
    }

    /// One raw LCG draw, 0...32767 — bits 30..16 of the advanced state (the Borland constant 0x015A4E35).
    public mutating func next() -> Int16 {
        state = 0x015A_4E35 &* state &+ 1
        return Int16((state >> 16) & 0x7FFF)
    }

    /// A uniform draw in `[min, max]` (inclusive), with `min`/`max` swapped if out of order — the
    /// rejection loop and integer scaling mirror `Tools_RandomLCG_Range` exactly. The span is computed
    /// in 32-bit (as C's int promotion does), so the `+ 1` cannot wrap.
    public mutating func range(_ min: UInt16, _ max: UInt16) -> UInt16 {
        var lo = min
        var hi = max
        if lo > hi { swap(&lo, &hi) }

        let span = Int32(hi) - Int32(lo) + 1
        var result: UInt16
        repeat {
            let value = Int32(next()) * span / 0x8000 + Int32(lo)
            result = UInt16(truncatingIfNeeded: value)
        } while result > hi
        return result
    }
}
