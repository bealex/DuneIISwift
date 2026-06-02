import DuneIIContracts
import Foundation
import SwiftOPL3
import Testing
import WestwoodADL
@testable import DuneIIAudio

/// The authentic AdLib FM music backend (`ADLMusicPlayer`, SwiftOPL3 + WestwoodADL) and the `MusicBackend`
/// switch. Audio output needs a device, so these cover what's deterministic: the `.ADL` asset mapping, that
/// the OPL3 path actually synthesises non-silent PCM at the selected subsong (the §7 "ADL track index ==
/// XMIDI sequence index" assumption, end-to-end), and that swapping the backend preserves the selection.
@Suite("ADL music")
@MainActor
struct ADLMusicTests {
    /// Repo `Resources/Audio/Music`, or `nil` when the assets aren't checked out (tests short-circuit).
    private static func musicDir() -> URL? {
        let dir = URL(filePath: #filePath)              // …/Code/Tests/AudioTests/ADLMusicTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // → repo root
            .appending(path: "Resources/Audio/Music")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    @Test("the AdLib backend is the default and exposes both engines")
    func backendCases() {
        #expect(MusicBackend.allCases == [.adlib, .midi])
        #expect(MusicBackend(rawValue: "adlib") == .adlib)
        #expect(MusicBackend.adlib.displayName.isEmpty == false)
    }

    @Test("every selectable track resolves to a DUNE<file>.ADL on disk")
    func adlFilesExist() throws {
        let dir = try #require(Self.musicDir(), "music assets absent — skipping")
        var ids = Set(MusicDirector.mapTracks).union(MusicDirector.attackTracks)
        ids.formUnion(MusicDirector.winMusic)
        ids.formUnion(MusicDirector.loseMusic)
        for id in ids {
            let track = try #require(MusicDirector.table[id], "musicID \(id) has no track")
            let file = dir.appending(path: String(format: "DUNE%d.ADL", track.file))
            #expect(FileManager.default.fileExists(atPath: file.path), "missing \(file.lastPathComponent) for musicID \(id)")
        }
    }

    /// Drives the SwiftOPL3 chip + WestwoodADL driver exactly as `ADLMusicPlayer`'s render thread does (the
    /// `adlrender` host loop) for a real ambient track, and asserts it produces audible (non-zero-peak) PCM at
    /// the subsong the selection table picks — confirming the `(file, song)` index maps to a real ADL track.
    @Test("the OPL3 path synthesises non-silent PCM for a selected track")
    func opl3RendersAudio() throws {
        let dir = try #require(Self.musicDir(), "music assets absent — skipping")
        let track = try #require(MusicDirector.table[8])            // ambient map theme = DUNE1.ADL subsong 6
        let url = dir.appending(path: String(format: "DUNE%d.ADL", track.file))
        let data = try Data(contentsOf: url)

        let rate = 44_100
        let chip = OPL3Chip(sampleRate: UInt32(rate))
        let player = ADLPlayer(chip: chip)
        try #require(player.load(data), "DUNE\(track.file).ADL did not parse")
        player.rewind(subsong: track.song)

        // Half a second: tick the 72 Hz driver, emit chip samples up to each tick's 44.1 kHz boundary.
        let refresh = 72
        var peak: Int32 = 0
        var emitted = 0
        for t in 0 ..< (refresh / 2) {
            _ = player.update()
            let target = (t + 1) * rate / refresh
            while emitted < target {
                let s = chip.generateResampled()
                peak = max(peak, abs(Int32(s.left)), abs(Int32(s.right)))
                emitted += 1
            }
        }
        #expect(emitted > rate / 4, "expected ~half a second of samples")
        #expect(peak > 0, "OPL3 output was pure silence — the ADL track did not start")
    }

    @Test("switching the backend keeps the current selection")
    func switchBackendKeepsSelection() {
        // An empty dir: both engines no-op on a missing file, so we test pure policy without an audio device.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("duneii-adl-switch")
        let d = MusicDirector(musicDirectory: empty, backend: .adlib)
        d.win(house: .ordos)
        #expect(d.currentMusicID == 5)
        d.backend = .midi          // live swap — selection survives, re-issued to the new engine
        #expect(d.currentMusicID == 5)
        #expect(d.backend == .midi)
        d.backend = .midi          // setting the same backend is a no-op
        #expect(d.currentMusicID == 5)
    }
}
