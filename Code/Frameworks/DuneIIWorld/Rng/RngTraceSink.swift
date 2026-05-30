import Synchronization

/// An opt-in recorder for RNG draws, used to **trace-align our streams against the OpenDUNE oracle's**
/// `--parity-random-trace` / `--parity-lcg-trace` when a scenario golden diverges. Under a fixed seed and
/// the same headless harness, a faithful transcription draws the *same number and order* of bytes as the
/// oracle — so the first index where our draw stream differs from the oracle's points straight at a
/// missing / extra / reordered draw (i.e. a missing or mis-ported piece of logic). See the insight
/// `sim-rng-stream-unpinned-wobble` and `Documentation/Architecture/ScenarioHarness.md`.
///
/// A **reference type** so a single sink is shared across all value-copies of `Random256`/`RandomLCG`
/// (assign it to `state.random256.traceSink` + `state.randomLCG.traceSink`). `Sendable` via `Mutex`,
/// per the project's concurrency rules (no `@unchecked`). When a struct's `traceSink` is `nil` (the
/// default — production + every non-tracing test) recording is a single nil-check, so it is free.
public final class RngTraceSink: Sendable {
    public struct Draw: Sendable, Equatable {
        public var tick: UInt32
        public var value: UInt16   // a Random256 byte (0…255) or a RandomLCG_Range result
        public init(tick: UInt32, value: UInt16) { self.tick = tick; self.value = value }
    }

    private struct State {
        var tick: UInt32 = 0
        var r256: [Draw] = []
        var lcg: [Draw] = []
    }
    private let storage = Mutex(State())

    public init() {}

    /// Tag subsequent draws with the current game tick (set this from the driver before each `tick()`),
    /// so the recorded stream lines up with the oracle's per-tick trace.
    public func setTick(_ tick: UInt32) { storage.withLock { $0.tick = tick } }

    /// Record one `Tools_Random_256` draw (called from `Random256.next`).
    public func recordR256(_ value: UInt8) { storage.withLock { $0.r256.append(Draw(tick: $0.tick, value: UInt16(value))) } }

    /// Record one `Tools_RandomLCG_Range` result (called from `RandomLCG.range`; the internal rejection
    /// draws are *not* logged, mirroring the oracle, which traces the range wrapper, not raw `Tools_RandomLCG`).
    public func recordLCG(_ value: UInt16) { storage.withLock { $0.lcg.append(Draw(tick: $0.tick, value: value)) } }

    public var r256: [Draw] { storage.withLock { $0.r256 } }
    public var lcg: [Draw] { storage.withLock { $0.lcg } }

    /// One entry of an oracle trace file line (`tick=… idx=… byte=0x… ctx=…` or `… value=… ctx=…`).
    public struct OracleDraw: Sendable, Equatable {
        public var tick: UInt32, idx: UInt32, value: UInt16, ctx: String
        public init(tick: UInt32, idx: UInt32, value: UInt16, ctx: String) {
            self.tick = tick; self.idx = idx; self.value = value; self.ctx = ctx
        }
    }

    /// Parse an oracle `--parity-random-trace` / `--parity-lcg-trace` file. Lines look like
    /// `tick=6 idx=1 byte=0xC2 ctx=u22` (R256) or `tick=1 idx=0 value=0 ctx=u23` (LCG). Unknown lines are skipped.
    public static func parseOracleTrace(_ text: String) -> [OracleDraw] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var tick: UInt32?, idx: UInt32?, value: UInt16?, ctx = "NULL"
            for field in line.split(separator: " ") {
                let kv = field.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let (k, v) = (String(kv[0]), String(kv[1]))
                switch k {
                    case "tick":  tick = UInt32(v)
                    case "idx":   idx = UInt32(v)
                    case "ctx":   ctx = v
                    case "byte":  value = v.hasPrefix("0x") ? UInt16(v.dropFirst(2), radix: 16) : UInt16(v)
                    case "value": value = UInt16(v)
                    default: break
                }
            }
            guard let tick, let idx, let value else { return nil }
            return OracleDraw(tick: tick, idx: idx, value: value, ctx: ctx)
        }
    }

    /// The first index at which our recorded `draws` diverge from the parsed `oracle` trace — either a
    /// value mismatch or a length mismatch (a missing/extra draw). `nil` if the streams agree over the
    /// shorter length and have equal length. The returned message names the index, both values, and the
    /// oracle's tick/ctx — pointing at the exact draw site to fix.
    public static func firstDivergence(ours draws: [Draw], oracle: [OracleDraw], label: String) -> String? {
        for i in 0 ..< Swift.min(draws.count, oracle.count) where draws[i].value != oracle[i].value {
            return "\(label) draw #\(i) diverges: ours=0x\(String(draws[i].value, radix: 16)) (our tick \(draws[i].tick)) "
                 + "vs oracle=0x\(String(oracle[i].value, radix: 16)) (oracle tick \(oracle[i].tick), ctx=\(oracle[i].ctx)) "
                 + "→ a mis-ported draw at/just before ctx=\(oracle[i].ctx)."
        }
        if draws.count != oracle.count {
            let i = Swift.min(draws.count, oracle.count)
            let who = draws.count < oracle.count ? "we are MISSING a draw" : "we made an EXTRA draw"
            let oracleCtx = i < oracle.count ? "ctx=\(oracle[i].ctx) tick \(oracle[i].tick)" : "(past end)"
            return "\(label) draw-count mismatch at #\(i) (\(who)): ours=\(draws.count) vs oracle=\(oracle.count); "
                 + "next oracle draw is \(oracleCtx) → a missing/extra draw there."
        }
        return nil
    }
}
