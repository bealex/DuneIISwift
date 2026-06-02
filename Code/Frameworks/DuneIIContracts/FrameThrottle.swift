/// A tiny per-frame rate limiter: fires every `interval`-th `tick()`, used to run a piece of presentation
/// work (a texture rebuild, a HUD derivation) at a fraction of the display rate when 60 Hz is wasteful and
/// imperceptibly different from, say, 10 Hz. Presentation-only — never gate simulation state on this
/// (determinism lives in `GameState`); it shapes how often the host *recomputes what it shows*, not what
/// the sim does.
///
/// `interval == 1` fires every call — the neutral default, so a consumer that leaves it at 1 behaves
/// exactly as if the throttle were absent (the render/scenario goldens stay byte-identical). The host opts
/// into a coarser cadence by constructing with a larger interval. The first `tick()` always fires, so
/// initial state populates immediately rather than after a delay.
public struct FrameThrottle: Sendable {
    /// Fire one call in every `interval` (clamped to ≥ 1).
    public let interval: Int
    private var counter = 0

    public init(every interval: Int) {
        self.interval = max(1, interval)
    }

    /// Advance one frame; returns `true` on the frames the throttled work should run (calls 0, interval,
    /// 2·interval, …). Always advances the counter, so callers can `||` it with an override condition (an
    /// interaction that must refresh immediately) without losing the cadence.
    public mutating func tick() -> Bool {
        let fire = counter % interval == 0
        counter += 1
        return fire
    }
}
