import AppKit
import DuneIIAudio
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// Loading a scenario must not start the real audio engine or music when nothing is explicitly testing audio.
/// `GameModel` is silent by default (audio is opt-in); `audioEnabled: true` is what the real clients pass.
/// Regression for "audio plays the moment a scenario loads in a test". Skips without the install.
@MainActor
struct AudioDisableTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The default path: both master gates stay shut and no track is playing after the init-time scenario load.
    @Test func loadingAScenarioIsSilentByDefault() throws {
        guard let installURL else { print("audio-disable: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))  // loads the first scenario in init
        #expect(model.audioEnabled == false, "audio must default off (opt-in)")
        #expect(model.audio.enabled == false, "the SFX gate must stay shut")
        #expect(model.music.enabled == false, "the music gate must stay shut")
        #expect(model.music.currentMusicID == 0, "no music track should have started on load")
    }

    /// An explicit `audioEnabled: false` forces the same silence regardless of the harness.
    @Test func explicitDisableIsSilent() throws {
        guard let installURL else { print("audio-disable: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL), audioEnabled: false)
        #expect(model.audioEnabled == false)
        #expect(model.music.currentMusicID == 0, "no music track should have started on load")
    }

    /// An explicit `audioEnabled: true` opens the gates and routes a map theme on load — the positive branch.
    @Test func explicitEnableStartsMusic() throws {
        guard let installURL else { print("audio-disable: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL), audioEnabled: true)
        defer { model.music.stop() }  // don't leave a track playing past the test
        #expect(model.audioEnabled == true)
        #expect(model.music.enabled == true, "the music gate must be open")
        #expect((8 ... 15).contains(model.music.currentMusicID), "a map theme (8–15) should start")
    }
}
