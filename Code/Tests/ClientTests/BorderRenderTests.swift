import AppKit
import Foundation
import SpriteKit
import Testing

@testable import DuneIIClient

/// Verifies the decorative map border ring is actually built around the playable area in the real
/// `GameScene` (it was reported "fully black"). Uses the `debugBorderStrips` test seam. Skips without install.
@MainActor
struct BorderRenderTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func borderRingIsBuilt() throws {
        guard let installURL else { print("border-render: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))  // loads the first scenario in init
        let scene = model.scene!
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1100, height: 1100))
        view.presentScene(scene)
        for i in 0 ..< 8 { scene.update(Double(i) * 0.1) }  // advance the sim + build the border

        let strips = scene.debugBorderStrips
        print("border-render: \(strips.count) strips; sizes \(strips.map { "\(Int($0.size.width))x\(Int($0.size.height))" })")
        #expect(strips.count >= 4, "border ring not built (strip count \(strips.count))")
        // The strips must be attached to the scene — `load()` once orphaned `borderLayer` via its keep-list,
        // so the strips existed (with textures) but never rendered (black margin).
        #expect(strips.allSatisfy { $0.scene != nil }, "border strips are detached from the scene (won't render)")

        // The strip texture must not be black (the reported bug) — check the first strip's pixels.
        guard let cg = strips.first?.texture?.cgImage(), let raw = cg.dataProvider?.data as Data? else { return }
        var bright = 0
        let bpr = cg.bytesPerRow
        for y in 0 ..< cg.height {
            for x in 0 ..< cg.width {
                let o = y * bpr + x * 4
                if Int(raw[o]) > 60 || Int(raw[o + 1]) > 60 || Int(raw[o + 2]) > 60 { bright += 1 }
            }
        }
        print("border-render: first strip \(cg.width)x\(cg.height), bright px=\(bright)")
        #expect(bright > 50, "border strip texture is (near-)black")
    }
}
