import Testing

@testable import DuneIIRenderer

/// The sandworm heat-haze rebuild — the biggest per-frame `SKTexture` upload — is rate-limited by
/// `SpriteKitRenderer.shimmerUpdateInterval`. These verify the throttle skips rebuilds, and that the
/// default (interval 1) rebuilds every frame (the neutrality bar — what the worm render golden captures).
/// Install-gated: short-circuits like the render goldens when the original install is absent.
@Suite("Shimmer throttle")
struct ShimmerThrottleTests {
    private static let wormCase = RenderHarness.Case(
        "throttle-probe",
        scenario: "SCENA001.INI",
        tick: 0,
        worm: (35, 22)
    )

    @MainActor
    @Test("interval 2 rebuilds the shimmer every other frame")
    func throttledHalvesRebuilds() {
        guard let p = RenderHarness.prepare(Self.wormCase) else { return }
        p.renderer.shimmerUpdateInterval = 2
        for _ in 0 ..< 4 { p.renderer.render(p.frame) }
        // Frames fire on calls 0 and 2 → 2 rebuilds across 4 renders.
        #expect(p.renderer.shimmerRebuildCount == 2)
    }

    @MainActor
    @Test("default interval 1 rebuilds every frame (golden-neutral)")
    func defaultRebuildsEveryFrame() {
        guard let p = RenderHarness.prepare(Self.wormCase) else { return }
        #expect(p.renderer.shimmerUpdateInterval == 1)
        for _ in 0 ..< 4 { p.renderer.render(p.frame) }
        #expect(p.renderer.shimmerRebuildCount == 4)
    }
}
