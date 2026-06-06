import CoreGraphics
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
        // A winger (ornithopter) parked over the Harkonnen base: its drop shadow (`ShadowEffect`) darkens
        // the building/concrete beneath it, offset (+1,+3) — the "crash site over a building looks weird"
        // fix (the shadow was previously not drawn at all). Tick 0 so the unit stays put over the structure.
        .init("scena005-air-shadow-t0", scenario: "SCENA005.INI", tick: 0, rect: (40, 41, 12, 12), air: (46, 46)),
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

    /// Proves the winger drop shadow actually paints pixels (so the golden above genuinely guards it, not an
    /// inert no-op): render the air-shadow frame as captured, then render the same frame with the
    /// ornithopter's `hasShadow` cleared, and require the two images to differ. The difference is exactly the
    /// `ShadowEffect` patch under the body's offset silhouette.
    @Test
    func airUnitCastsShadow() throws {
        let c = Self.cases.first { $0.name == "scena005-air-shadow-t0" }!
        guard let p = RenderHarness.prepare(c) else {
            print("air-shadow integration: no install / GPU — skipped"); return
        }

        let crop = c.rect.map {
            CGRect(x: $0.x * p.tileSize, y: $0.y * p.tileSize, width: $0.w * p.tileSize, height: $0.h * p.tileSize)
        }
        guard let withShadow = p.renderer.snapshot(p.frame, crop: crop) else {
            print("air-shadow integration: no GPU context — skipped"); return
        }

        // The same frame with the shadow suppressed (clear `hasShadow` on every unit).
        var bare = p.frame
        for i in bare.units.indices { bare.units[i].hasShadow = false }
        let withoutShadow = try #require(p.renderer.snapshot(bare, crop: crop))

        let d = PngImage(withShadow).diff(PngImage(withoutShadow))
        #expect(d.mismatches > 0, "the drop shadow must change pixels vs the no-shadow render")
    }
}
