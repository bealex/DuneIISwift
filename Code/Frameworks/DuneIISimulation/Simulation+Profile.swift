import DuneIIWorld

/// Per-phase wall-clock breakdown of a single `tick()`, in seconds. Produced by `Simulation.tickProfiled()`
/// (an additive, parity-neutral measurement path — the ordinary `tick()` computes the identical state and
/// is never affected). The four buckets mirror the four game-loop phases; `other` is the preamble + level-end
/// + the visual (animation/explosion) tail. Used by the headless profiler (`duneii-headless profile`) and the
/// render-profiling tests to find where a heavy tick spends its time. See `Documentation/Architecture/Profiling.md`.
public struct PhaseTimings: Sendable {
    public var team = 0.0
    public var unit = 0.0
    public var structure = 0.0
    public var house = 0.0
    public var other = 0.0
    /// How many ticks were folded into these sums (so callers can report a per-tick average).
    public var ticks = 0

    public init() {}

    public var total: Double { team + unit + structure + house + other }

    /// Accumulate another tick's timings into a running total (one `+= ` per profiled tick).
    public static func += (lhs: inout PhaseTimings, rhs: PhaseTimings) {
        lhs.team += rhs.team
        lhs.unit += rhs.unit
        lhs.structure += rhs.structure
        lhs.house += rhs.house
        lhs.other += rhs.other
        lhs.ticks += rhs.ticks
    }
}

public extension Simulation {
    /// Advance one tick like `tick()`, but return a per-phase wall-clock breakdown. Behaviourally identical
    /// to `tick()` (same logic, same RNG order, same state) — it only wraps the four phase calls in a clock
    /// read, so it is safe to substitute in any profiling driver. Never used on the golden/parity path.
    mutating func tickProfiled() -> PhaseTimings {
        runTick(profile: true)
    }
}

/// Seconds (as a `Double`) for a `ContinuousClock.Duration`. Public so the render-profiling tests share it.
public func seconds(_ d: ContinuousClock.Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}
