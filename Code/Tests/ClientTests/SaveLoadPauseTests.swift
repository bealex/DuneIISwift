import AppKit
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// Loading a saved game must resume play, not leave it stuck paused. A save is written while the save/load
/// UI has the game paused, so `state.paused` is almost always `true` in the file; `finishLoad` must not
/// inherit that as the player's pause. Regression for "after a load, the game stays paused". Skips without
/// the install.
@MainActor
struct SaveLoadPauseTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func loadingAPausedSaveResumesPlaying() throws {
        guard let installURL else { print("save-load-pause: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))  // loads the first scenario in init
        guard var state = model.simulation?.state else { Issue.record("no simulation after load"); return }

        // Emulate a save written while the save dialog paused the game.
        state.paused = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dune2-paused-save.dat")
        try SaveGame.save(state).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(model.loadGame(from: url))
        #expect(model.paused == false, "a loaded game must resume playing, not stay paused")
        #expect(model.simulation?.state.paused == false, "the loaded simulation must be unpaused")
    }
}
