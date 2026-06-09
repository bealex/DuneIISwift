import CoreGraphics
import DuneIISimulation
import Foundation
import Testing

/// Render-profiling harness — the presentation-side counterpart to the headless tick profiler
/// (`duneii-headless profile`). It loads a **heavy** late-game scenario through the real sim + the real
/// `SpriteKitRenderer`, then separately times the two per-frame render stages:
///
///   1. `Simulation.makeFrameInfo()` — the pure `GameState → FrameInfo` snapshot the host rebuilds every
///      drawn frame (the CPU stage; `Parallelization.md` §4b flags it as the cleanest parallel win),
///   2. `SpriteKitRenderer.render()` — the **live** per-frame node/texture/palette update the on-screen app
///      pays each frame (no GPU read-back), and
///   3. `SpriteKitRenderer.snapshot()` — `render()` **plus** a full-map GPU→CPU `texture(from:)` read-back +
///      `CGImage`. This is the **capture** path (goldens / `rendercap`), not the live cost — the read-back
///      dominates it, so it is reported separately so the two are never conflated.
///
/// It is a **measurement** seam, not a golden: there is no oracle for "how fast should a frame render",
/// and wall-clock numbers are machine-dependent, so the bounds are deliberately loose (catch a gross
/// regression / an accidental O(n²), never flake on a slow box). The numbers are `print`ed for inspection.
/// Skips (passes) when the install is absent or no off-screen GPU context exists — same as the render
/// goldens. Run it directly with `swift test --filter RenderProfilingTests`.
@MainActor
struct RenderProfilingTests {
    /// A deliberately heavy frame: the full 64×64 map of a built-up late-game Harkonnen base (SCENH022),
    /// fog on, advanced 200 ticks so production/units are live. `rect: nil` ⇒ the renderer composites the
    /// whole map — the worst case for the snapshot stage.
    static let heavyCase = RenderHarness.Case(
        "profile-scenh022-full",
        scenario: "SCENH022.INI",
        tick: 200,
        rect: nil,
        fog: true
    )

    @Test("render profiling: time makeFrameInfo + full-map snapshot on a heavy scenario")
    func profileHeavyFrame() throws {
        guard RenderHarness.installURL != nil else { print("render-profile: no install — skipped"); return }
        guard
            let p = RenderHarness.prepare(Self.heavyCase)
        else {
            print("render-profile: no off-screen GPU context — skipped"); return
        }

        let units = p.frame.units.count, structures = p.frame.structures.count
        print("render-profile: SCENH022 @t200  units \(units)  structures \(structures)  (full 64×64 map, fog on)")

        // 1. makeFrameInfo — a pure CPU read; warm once, then time many iterations.
        _ = p.sim.makeFrameInfo()
        let frameIters = 200
        let clock = ContinuousClock()
        let makeStart = clock.now
        for _ in 0 ..< frameIters { _ = p.sim.makeFrameInfo() }
        let makeMs = seconds(makeStart.duration(to: clock.now)) / Double(frameIters) * 1000

        // 2. render — the live per-frame update path (the app pays this, no read-back). Warm once.
        p.renderer.render(p.frame)
        let renderIters = 60
        let renderStart = clock.now
        for _ in 0 ..< renderIters { p.renderer.render(p.frame) }
        let renderMs = seconds(renderStart.duration(to: clock.now)) / Double(renderIters) * 1000

        // 3. snapshot — render() + the full-map GPU→CPU read-back (the capture path); warm once.
        guard
            let warm = p.renderer.snapshot(p.frame, crop: nil)
        else {
            print("render-profile: snapshot returned nil — skipped"); return
        }

        let snapIters = 20
        let snapStart = clock.now
        for _ in 0 ..< snapIters { _ = p.renderer.snapshot(p.frame, crop: nil) }
        let snapMs = seconds(snapStart.duration(to: clock.now)) / Double(snapIters) * 1000

        print(String(format: "render-profile:   makeFrameInfo   %.4f ms/frame  (×%d)", makeMs, frameIters))
        print(
            String(
                format: "render-profile:   render (live)   %.4f ms/frame  (×%d)  → ~%.0f fps",
                renderMs,
                renderIters,
                renderMs > 0 ? 1000 / renderMs : 0
            )
        )
        print(
            String(
                format: "render-profile:   snapshot (capture, +read-back) %.4f ms/frame  (×%d)",
                snapMs,
                snapIters
            )
        )

        // Loose sanity bounds: the image composited, and no stage is pathologically slow. These guard
        // against a gross regression (an accidental per-frame O(n²) or a full re-decode), not jitter.
        #expect(warm.width > 0 && warm.height > 0)
        #expect(makeMs < 50, "makeFrameInfo unexpectedly slow: \(makeMs) ms/frame")
        #expect(renderMs < 500, "live render unexpectedly slow: \(renderMs) ms/frame")
        #expect(snapMs < 2000, "snapshot unexpectedly slow: \(snapMs) ms/frame")
    }
}
