import DuneIIContracts
import Foundation
import Testing

@testable import DuneIIAudio

/// `MusicDirector` — the music-selection policy transcribed from OpenDUNE (`g_table_musics` +
/// `g_table_houseInfo`). Audio output needs a device, so these cover the *selection* logic: the table is
/// verbatim, the filename mapping is right, every track the policy can pick exists on disk, and the random
/// pools land in OpenDUNE's ranges.
@Suite("MusicDirector")
@MainActor
struct MusicDirectorTests {
    /// Deterministic RNG (SplitMix64) so the random-pool tests are repeatable.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A directory with no MIDI files: `MusicPlayer` no-ops on a missing file, so the director still records
    /// its selection in `currentMusicID` without touching `AVMIDIPlayer` — lets us assert pure policy.
    private func director(seed: UInt64) -> MusicDirector {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("duneii-no-music-\(seed)")
        return MusicDirector(musicDirectory: empty, rng: SeededRNG(seed: seed))
    }

    @Test("g_table_musics is transcribed verbatim (38 entries, key IDs)")
    func table() {
        #expect(MusicDirector.table.count == 38)
        #expect(MusicDirector.table[0] == nil)  // silence
        #expect(MusicDirector.table[5]! == (17, 4))  // Ordos/Fremen win
        #expect(MusicDirector.table[6]! == (8, 3))  // Harkonnen/Sardaukar win
        #expect(MusicDirector.table[7]! == (8, 2))  // Atreides/Mercenary win
        #expect(MusicDirector.table[8]! == (1, 6))  // first map track
        #expect(MusicDirector.table[15]! == (9, 5))  // last map track
        #expect(MusicDirector.table[17]! == (10, 7))  // first attack track
        #expect(MusicDirector.table[22]! == (15, 7))  // last attack track
        #expect(MusicDirector.table[24]! == (7, 2))  // Harkonnen briefing
    }

    @Test("previewTracks lists every non-silent table entry with its (file, song)")
    func previewTracks() {
        let tracks = MusicDirector.previewTracks
        let expectedCount = MusicDirector.table.dropFirst().compactMap { $0 }.count
        #expect(tracks.count == expectedCount)
        #expect(tracks.allSatisfy { $0.id > 0 })
        // Each track resolves to its table entry, and IDs are unique + in order.
        for track in tracks { #expect(MusicDirector.table[track.id]! == (track.file, track.song)) }
        #expect(tracks.map(\.id) == tracks.map(\.id).sorted())
        #expect(Set(tracks.map(\.id)).count == tracks.count)
        #expect(tracks.first(where: { $0.id == 24 })?.name.contains("Briefing · Harkonnen") == true)
    }

    @Test("per-house win/lose/briefing IDs match g_table_houseInfo")
    func houseMusic() {
        // Harkonnen, Atreides, Ordos, Fremen, Sardaukar, Mercenary
        #expect(MusicDirector.winMusic == [ 6, 7, 5, 5, 6, 7 ])
        #expect(MusicDirector.loseMusic == [ 3, 4, 2, 2, 3, 4 ])
        #expect(MusicDirector.briefingMusic == [ 24, 25, 26, 0xFFFF, 0xFFFF, 0xFFFF ])
    }

    @Test("filename zero-pads the song index")
    func filename() {
        #expect(MusicPlayer.filename(file: 1, song: 6) == "DUNE1.06.mid")
        #expect(MusicPlayer.filename(file: 10, song: 7) == "DUNE10.07.mid")
        #expect(MusicPlayer.filename(file: 0, song: 2) == "DUNE0.02.mid")
    }

    @Test("startInGame picks a map track (8–15); enterBattle picks an attack track (17–22)")
    func randomPools() {
        let d = director(seed: 0xD0_0D)
        for _ in 0 ..< 200 {
            d.startInGame()
            #expect(MusicDirector.mapTracks.contains(d.currentMusicID))
            d.enterBattle()
            #expect(MusicDirector.attackTracks.contains(d.currentMusicID))
        }
    }

    @Test("win/lose select the player house's stinger; invalid musicID is a no-op")
    func stingers() {
        let d = director(seed: 1)
        d.win(house: .ordos)
        #expect(d.currentMusicID == 5)  // Ordos win
        d.lose(house: .atreides)
        #expect(d.currentMusicID == 4)  // Atreides lose
        // 0xFFFF (a disabled briefing) / out-of-range / silence all stop and reset to 0.
        #expect(d.play(musicID: 0xFFFF, loop: true) == false)
        #expect(d.currentMusicID == 0)
        #expect(d.play(musicID: 99, loop: false) == false)
    }

    @Test("disabled director never selects anything")
    func disabled() {
        let d = director(seed: 7)
        d.enabled = false
        d.startInGame(); d.enterBattle(); d.win(house: .harkonnen)
        #expect(d.currentMusicID == 0)
    }

    /// Real data: every track the policy can pick (map, attack, all house win/lose/briefing) must resolve to
    /// a real file in `Resources/Audio/Music/`. Short-circuits when the assets aren't present.
    @Test("every selectable track exists on disk")
    func tracksExistOnDisk() throws {
        let musicDir = URL(filePath: #filePath)  // …/Code/Tests/AudioTests/MusicDirectorTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()  // → repo root
            .appending(path: "Resources/Audio/Music")
        try #require(FileManager.default.fileExists(atPath: musicDir.path), "music assets absent — skipping")

        var ids = Set(MusicDirector.mapTracks).union(MusicDirector.attackTracks)
        ids.formUnion(MusicDirector.winMusic)
        ids.formUnion(MusicDirector.loseMusic)
        ids.formUnion(MusicDirector.briefingMusic.filter { $0 != 0xFFFF })

        for id in ids {
            let track = try #require(MusicDirector.table[id], "musicID \(id) has no track")
            let file = musicDir.appending(path: MusicPlayer.filename(file: track.file, song: track.song))
            #expect(
                FileManager.default.fileExists(atPath: file.path),
                "missing \(file.lastPathComponent) for musicID \(id)"
            )
        }
    }
}
