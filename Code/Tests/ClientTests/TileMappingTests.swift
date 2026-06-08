import AppKit
import Foundation
import SpriteKit
import Testing

@testable import DuneIIClient

/// Verifies `GameScene.tile(atScenePoint:)` rejects points outside the playable square instead of snapping
/// just-off-map clicks to an edge tile. Regression: integer division truncates toward zero, so a click in the
/// scrollable border margin (scene x ∈ [-borderPx, 0)) collapsed to tile 0 and slipped past the `0 ..< 64`
/// guard. Pure geometry; uses the real scene but no sim state. Skips without install (the only way to build a
/// `GameScene` is through a `GameModel`, which needs the asset store).
@MainActor
struct TileMappingTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func makeScene() -> GameScene? {
        guard let installURL else { print("tile-mapping: no install — skipped"); return nil }
        NSApplication.shared.setActivationPolicy(.accessory)
        return GameModel(assets: AssetStore(installURL: installURL)).scene
    }

    /// In-bounds scene points map to the expected 0-63 tile, with the y-flip (scene y-up → tile y-down).
    @Test func inBoundsPointsMapToTiles() throws {
        guard let scene = makeScene() else { return }

        // Bottom-left of the scene (y-up) is the bottom row of the map (y-down → row 63).
        #expect(scene.tile(atScenePoint: CGPoint(x: 8, y: 8)).map { $0 == (0, 63) } ?? false)
        // Top-left of the scene is the origin tile (0, 0).
        #expect(scene.tile(atScenePoint: CGPoint(x: 8, y: 1023)).map { $0 == (0, 0) } ?? false)
        // A mid-map point: x=400 → col 25, sceneY=623 → row (1024-623)/16 = 25.
        #expect(scene.tile(atScenePoint: CGPoint(x: 400, y: 623)).map { $0 == (25, 25) } ?? false)
    }

    /// Points in the scrollable border margin just off the playable square must return nil, not snap to an
    /// edge tile (the bug: `Int(-8) / 16 == 0` passed the `0 ..< 64` guard as column 0).
    @Test func offMapMarginReturnsNil() throws {
        guard let scene = makeScene() else { return }

        #expect(scene.tile(atScenePoint: CGPoint(x: -8, y: 500)) == nil)    // left margin
        #expect(scene.tile(atScenePoint: CGPoint(x: -0.5, y: 500)) == nil)  // just left of x=0
        #expect(scene.tile(atScenePoint: CGPoint(x: 500, y: 1030)) == nil)  // above the top edge
        #expect(scene.tile(atScenePoint: CGPoint(x: 500, y: -4)) == nil)    // below the bottom edge
        #expect(scene.tile(atScenePoint: CGPoint(x: 1024, y: 500)) == nil)  // exactly the right edge
        #expect(scene.tile(atScenePoint: CGPoint(x: 1040, y: 500)) == nil)  // right margin
    }
}
