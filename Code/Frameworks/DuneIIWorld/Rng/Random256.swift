/// Dune II's primary pseudo-random generator: a 3-byte feedback generator returning a byte each call.
/// A bit-exact port of `Tools_Random_256` (OpenDUNE `src/tools.c:268`) with its seed state and
/// `Tools_Random_Seed` (`tools.c:308`). The scripts reach it via `General_DelayRandom`,
/// `Unit_RandomSoldier`, `Unit_GetRandomTile`, and others; `GameState` will own the live instance.
///
/// Verified bit-for-bit against an OpenDUNE golden dump (`Tests/WorldTests/Fixtures/rng-golden.jsonl`,
/// produced by `opendune --parity-golden`). See `Documentation/Algorithms/Rng.md`.
public struct Random256: Sendable {
    /// The 3 active feedback bytes (a 4th seed byte is loaded but unused, mirroring OpenDUNE).
    private var seed: (UInt8, UInt8, UInt8)

    /// Opt-in draw recorder (a shared reference) for parity trace-alignment. `nil` in production and in
    /// every non-tracing test — then `next()` only nil-checks it. See `RngTraceSink`.
    public var traceSink: RngTraceSink?

    public init(seed: UInt32 = 0) {
        self.seed = (0, 0, 0)
        reseed(seed)
    }

    /// `Tools_Random_Seed`: unpack a 32-bit seed little-endian into the byte state (top byte unused).
    public mutating func reseed(_ value: UInt32) {
        seed.0 = UInt8(value & 0xFF)
        seed.1 = UInt8((value >> 8) & 0xFF)
        seed.2 = UInt8((value >> 16) & 0xFF)
    }

    /// One draw, 0...255. Wrapping arithmetic (`&-`) and fixed-width shifts reproduce the C uint8/uint16
    /// truncation exactly.
    public mutating func next() -> UInt8 {
        var val16 = (UInt16(seed.1) << 8) | UInt16(seed.2)
        var val8 = UInt8(((val16 ^ 0x8000) >> 15) & 1)
        val16 = (val16 << 1) | UInt16((seed.0 >> 1) & 1)
        val8 = (seed.0 >> 2) &- seed.0 &- val8
        seed.0 = (val8 << 7) | (seed.0 >> 1)
        seed.1 = UInt8(val16 >> 8)
        seed.2 = UInt8(val16 & 0xFF)
        let result = seed.0 ^ seed.1
        traceSink?.recordR256(result)
        return result
    }
}
