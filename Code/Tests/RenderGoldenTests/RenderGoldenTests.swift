import Foundation
import Testing

/// Render-golden suite — the auto-test payoff of `SpriteKitRenderer.snapshot` and the Phase-4 DoD "diff a
/// rendered frame pixel-exact against a reference PNG". Each case runs a scenario to a tick through the real
/// sim, captures a region through the real renderer, and diffs it pixel-exact against a committed reference
/// (`Fixtures/<name>.png`).
///
/// Reference capture: `Scripts/gen-render-goldens.sh` (sets `DUNEII_RENDER_RECORD=1`, which makes each case
/// **write** its PNG instead of diffing). The same capture path produces the reference and the run-time
/// image, so they match exactly. Short-circuits (passes) when the install is absent or no off-screen GPU
/// context is available — the per-pixel composition is also covered headlessly by `FrameComposerTests`.
@MainActor
struct RenderGoldenTests {
    /// The committed cases. Small tile-space crops centred on the SCENA001 starting area keep references
    /// tiny and focused; add a case here, then re-run `gen-render-goldens.sh` to capture its reference.
    nonisolated static let cases: [RenderHarness.Case] = [
        .init("scena001-base-t0", scenario: "SCENA001.INI", tick: 0, rect: (26, 21, 14, 12)),
        .init("scena001-base-t60", scenario: "SCENA001.INI", tick: 60, rect: (26, 21, 14, 12)),
        .init("scena001-base-fog-t60", scenario: "SCENA001.INI", tick: 60, rect: (26, 21, 14, 12), fog: true),
        // A richer multi-structure enemy base: house-recoloured structures (red Harkonnen vs blue Atreides
        // player), concrete slabs, walls (the transparent overlay composite), infantry + vehicles.
        .init("scena005-base-t40", scenario: "SCENA005.INI", tick: 40, rect: (38, 40, 18, 14)),
        // A sandworm straddling the rock/sand boundary — the shimmer displaces the high-contrast terrain
        // under its silhouette (CoreGraphics blur). A still capture is subtle (the in-game shimmer animates).
        .init("scena001-worm-t0", scenario: "SCENA001.INI", tick: 0, rect: (32, 19, 7, 7), worm: (35, 22)),
        // The same worm with fog of war on: the shimmer must sample the **fog-free** terrain, so the worm
        // silhouette shows a clean heat-haze — never the dithered fog-edge checkerboard (which the fogged
        // terrain buffer bakes into still-`isUnveiled` edge tiles). Guards the fog-edge shimmer fix.
        .init(
            "scena001-worm-fog-t60",
            scenario: "SCENA001.INI",
            tick: 60,
            rect: (30, 20, 7, 7),
            fog: true,
            worm: (33, 23)
        ),
    ]

    static var recording: Bool { ProcessInfo.processInfo.environment["DUNEII_RENDER_RECORD"] != nil }

    @Test(arguments: cases)
    func renderGolden(_ c: RenderHarness.Case) throws {
        guard RenderHarness.installURL != nil else { print("render-golden \(c.name): no install — skipped"); return }
        guard
            let image = RenderHarness.capture(c)
        else {
            print("render-golden \(c.name): no off-screen GPU context — skipped"); return
        }

        let reference = RenderHarness.fixturesDir.appendingPathComponent("\(c.name).png")

        if Self.recording {
            try FileManager.default.createDirectory(at: RenderHarness.fixturesDir, withIntermediateDirectories: true)
            try PngImage.write(image, to: reference)
            print("render-golden \(c.name): recorded \(image.width)×\(image.height) → \(reference.lastPathComponent)")
            return
        }

        guard
            let expected = PngImage(contentsOf: reference)
        else {
            Issue.record(
                "render-golden \(c.name): missing reference \(reference.path) — run Scripts/gen-render-goldens.sh"
            )
            return
        }
        let actual = PngImage(image)
        let d = actual.diff(expected)
        let firstPx = d.first.map { "(\($0.x),\($0.y))" } ?? "-"
        let msg =
            "render-golden \(c.name): \(d.mismatches) px differ (max channel Δ \(d.maxDelta), first at "
            + "\(firstPx)); actual \(actual.width)×\(actual.height) vs reference \(expected.width)×\(expected.height)"
        #expect(d.mismatches == 0, Comment(rawValue: msg))
    }
}
