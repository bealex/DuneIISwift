import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

/// Golden-image screenshot tests. Each test loads the real install,
/// sets up a deterministic runtime state (scenario load + optional
/// click / placement), renders a tile rectangle via
/// `ScreenshotRenderer`, and compares pixel-exact against a PNG golden
/// checked into `Fixtures/Screenshots/`.
///
/// **Install-gated** — short-circuits when `TestInstall.locate()` is nil.
///
/// **Regenerating goldens**: set `DUNEII_REGENERATE_GOLDENS=1` in the
/// environment. The test writes the current render to disk instead of
/// asserting. Commit the new golden + unset the env var.
///
/// All mutations run at tick 0 (no `tick()` call) so positions /
/// orientations stay deterministic across platforms.
@MainActor
@Suite("Screenshot — golden-image rendering")
struct ScreenshotTests {

    private static let regenerateEnv = "DUNEII_REGENERATE_GOLDENS"

    /// Locates `<repo>/Code/Core/Tests/DuneIICoreTests/Fixtures/Screenshots/`
    /// relative to this file; creates it on demand when regenerating.
    private static func fixtureURL(name: String) -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let dir = here.deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
        return dir.appendingPathComponent(name)
    }

    /// Renders `runtime` into a PNG and either (a) writes it as the new
    /// golden when `DUNEII_REGENERATE_GOLDENS=1`, or (b) compares it
    /// pixel-exact against the existing golden and fails on any
    /// mismatched pixel. Missing-golden on normal runs is a failure —
    /// the regenerate flag must be explicit.
    private func assertGolden(
        runtime: ScenarioRuntime,
        origin: (x: Int, y: Int),
        size: (w: Int, h: Int),
        name: String
    ) throws {
        let renderer = ScreenshotRenderer(loader: runtime.assets)
        let pngData = try renderer.renderPNGData(
            runtime: runtime,
            originTileX: origin.x, originTileY: origin.y,
            widthTiles: size.w, heightTiles: size.h
        )
        let url = Self.fixtureURL(name: name)
        let regenerate = ProcessInfo.processInfo.environment[Self.regenerateEnv] == "1"

        if regenerate {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("golden missing at \(url.path) — run with \(Self.regenerateEnv)=1 to create")
            return
        }
        let goldenData = try Data(contentsOf: url)
        let (currentRGBA, cw, ch) = try Self.decodeRGBA(pngData: pngData)
        let (goldenRGBA, gw, gh) = try Self.decodeRGBA(pngData: goldenData)
        #expect(cw == gw && ch == gh,
                "size mismatch: current=\(cw)x\(ch) golden=\(gw)x\(gh) (\(name))")
        guard cw == gw && ch == gh else { return }
        if currentRGBA != goldenRGBA {
            // Persist the diff for eyeballing. Not a test dep — just
            // a developer convenience when a fixture breaks.
            let diffURL = url.deletingPathExtension()
                .appendingPathExtension("actual.png")
            try? pngData.write(to: diffURL)
            let mismatches = zip(currentRGBA, goldenRGBA)
                .lazy.filter(!=).prefix(1).count
            Issue.record("pixel mismatch in \(name) (≥\(mismatches) differing bytes). Actual written to \(diffURL.lastPathComponent).")
        }
    }

    private static func decodeRGBA(pngData: Data) throws -> (bytes: [UInt8], w: Int, h: Int) {
        guard let provider = CGDataProvider(data: pngData as CFData),
              let image = CGImage(
                pngDataProviderSource: provider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { throw DecodeError.pngDecodeFailed }
        let w = image.width
        let h = image.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = buf.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: cs, bitmapInfo: info
            )
        }) else { throw DecodeError.contextFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, w, h)
    }

    private enum DecodeError: Error {
        case pngDecodeFailed
        case contextFailed
    }

    private func loadMission1() throws -> ScenarioRuntime? {
        guard let installDir = TestInstall.locate() else { return nil }
        let installation = try Installation(rootDirectory: installDir)
        let assets = try AssetLoader(installation: installation)
        let runtime = ScenarioRuntime(assets: assets)
        try runtime.load(scenarioName: "SCENA001.INI")
        return runtime
    }

    // Common rect: covers the Atreides CYARD at (30, 25) and the
    // clump of player + Ordos units around it. 12×12 tiles = 192×192 px.
    private static let baseRect = (origin: (x: 24, y: 18), size: (w: 16, h: 16))

    // MARK: Tests

    @Test("initial load: terrain + CYARD footprint + spawned units render")
    func initialLoad() throws {
        guard let runtime = try loadMission1() else { return }
        try assertGolden(
            runtime: runtime,
            origin: Self.baseRect.origin,
            size: Self.baseRect.size,
            name: "mission1-initial.png"
        )
    }

    @Test("unit selection halo renders as a green circle around the selected unit")
    func unitHalo() throws {
        guard let runtime = try loadMission1() else { return }
        // Player trike at (29, 23) — idx=4, house=1.
        let outcome = runtime.leftClick(tileX: 29, tileY: 23)
        if case .unitSelected = outcome {} else {
            Issue.record("expected unitSelected outcome, got \(outcome)")
            return
        }
        try assertGolden(
            runtime: runtime,
            origin: Self.baseRect.origin,
            size: Self.baseRect.size,
            name: "mission1-unit-halo.png"
        )
    }

    @Test("structure halo renders as a green rectangle around the selected CYARD")
    func structureHalo() throws {
        guard let runtime = try loadMission1() else { return }
        // Anchor of the CYARD footprint. It's already auto-selected
        // on load, but a fresh click sets `selectedStructureIndex`
        // which drives the halo branch.
        _ = runtime.leftClick(tileX: 30, tileY: 25)
        try #require(runtime.selectedStructureIndex != nil)
        try assertGolden(
            runtime: runtime,
            origin: Self.baseRect.origin,
            size: Self.baseRect.size,
            name: "mission1-structure-halo.png"
        )
    }

    @Test("slab placement stamps the concrete tile on rock adjacent to CYARD")
    func slabPlacement() throws {
        guard let runtime = try loadMission1() else { return }
        // Force placementType to Slab 1x1 (type 0), commit at (32, 25)
        // — east of the CYARD (30..31 × 25..26), confirmed valid via
        // the headless `validity` probe.
        runtime.buildController.placementType = 0
        let outcome = runtime.leftClick(tileX: 32, tileY: 25)
        if case .placementCommitted = outcome {} else {
            Issue.record("slab placement rejected, got \(outcome)")
            return
        }
        try assertGolden(
            runtime: runtime,
            origin: Self.baseRect.origin,
            size: Self.baseRect.size,
            name: "mission1-slab-placed.png"
        )
    }

    @Test("windtrap placement stamps the 2×2 iconGroup footprint tiles")
    func windtrapPlacement() throws {
        guard let runtime = try loadMission1() else { return }
        // Windtrap is type 9 (2×2). Anchor (28, 25) puts the
        // footprint at (28..29 × 25..26) — west neighbour of the
        // CYARD, inside the capture rect. Validity = -4 (4 slabs
        // short but still placeable, which the renderer draws
        // faithfully via the iconGroup stamp).
        runtime.buildController.placementType = 9
        let outcome = runtime.leftClick(tileX: 28, tileY: 25)
        if case .placementCommitted = outcome {} else {
            Issue.record("windtrap placement rejected, got \(outcome)")
            return
        }
        try assertGolden(
            runtime: runtime,
            origin: Self.baseRect.origin,
            size: Self.baseRect.size,
            name: "mission1-windtrap-placed.png"
        )
    }
}
