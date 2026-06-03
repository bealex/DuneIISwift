import AVFoundation
import Foundation
import os

/// Plays Dune II's music through **AVFoundation's `AVMIDIPlayer`** — macOS's built-in MIDI sequencer +
/// synthesiser. This is the same role OpenDUNE delegates to FluidSynth/MUNT (`src/audio/midi_fluid.c`); it
/// is *not* an OPL2/AdLib chip emulation (neither is OpenDUNE's). The songs are the already-extracted
/// Standard-MIDI files in `Resources/Audio/Music/`, named `DUNE<file>.<song:02d>.mid`, where `<song>` is the
/// XMI sequence index — exactly the index OpenDUNE's `g_table_musics` uses (see `MusicDirector`).
///
/// Timbre comes from a **SoundFont/DLS bank**: `soundBank == nil` ⇒ the system's built-in General-MIDI DLS
/// bank (a GM approximation of the original AdLib voices); pass a `.sf2`/`.dls` URL for closer fidelity. The
/// bank is pluggable so a better SoundFont can be dropped in without touching this code.
///
/// Music is host-side presentation only: it never touches the simulation, `GameState`, or sim RNG, and
/// real-time playback is intentionally outside the deterministic-sim contract.
@MainActor
public final class MusicPlayer: MusicEngine {
    private let musicDirectory: URL
    private let soundBank: URL?
    private var player: AVMIDIPlayer?
    private var current: (file: Int, song: Int)?
    private var looping = false
    /// Bumped on every (re)start/stop/pause so a stale `play(completionHandler:)` callback from a player we
    /// have already superseded or stopped is ignored — `AVMIDIPlayer` gives us no other way to cancel it.
    private var generation = 0
    private var pausedPosition: TimeInterval?
    private let log = Logger(subsystem: "com.lonelybytes.duneii", category: "Music")

    /// Called when a non-looping track plays to its end (and was not stopped/paused). The director uses this
    /// to advance to the next ambient track.
    public var onFinished: (@MainActor () -> Void)?

    public init(musicDirectory: URL, soundBank: URL? = nil) {
        self.musicDirectory = musicDirectory
        self.soundBank = soundBank
    }

    /// `DUNE<file>.<song:02d>.mid` — the on-disk name for an OpenDUNE `(file, song)` pair.
    public static func filename(file: Int, song: Int) -> String {
        String(format: "DUNE%d.%02d.mid", file, song)
    }

    /// Start the song for `(file, song)`. `loop` restarts it on completion; otherwise `onFinished` fires at
    /// the end. A missing file is a no-op (logged) rather than a crash — the engine runs without the assets.
    public func play(file: Int, song: Int, loop: Bool) {
        let url = musicDirectory.appendingPathComponent(Self.filename(file: file, song: song))
        guard
            FileManager.default.fileExists(atPath: url.path)
        else {
            log.warning("music file missing: \(url.lastPathComponent, privacy: .public)")
            return
        }
        looping = loop
        current = (file, song)
        pausedPosition = nil
        start(url: url, from: nil)
    }

    public func stop() {
        generation &+= 1
        player?.stop()
        player = nil
        current = nil
        pausedPosition = nil
    }

    /// Freeze playback, remembering the position so `resume()` continues seamlessly.
    public func pause() {
        guard let player, player.isPlaying else { return }
        generation &+= 1  // invalidate the completion handler this stop may fire
        pausedPosition = player.currentPosition
        player.stop()
    }

    public func resume() {
        guard let current, let pausedPosition else { return }
        let url = musicDirectory.appendingPathComponent(Self.filename(file: current.file, song: current.song))
        start(url: url, from: pausedPosition)
        self.pausedPosition = nil
    }

    private func start(url: URL, from position: TimeInterval?) {
        generation &+= 1
        let token = generation
        do {
            let p = try AVMIDIPlayer(contentsOf: url, soundBankURL: soundBank)
            p.prepareToPlay()
            if let position { p.currentPosition = position }
            player = p
            log.info("music play \(url.lastPathComponent, privacy: .public) loop=\(self.looping, privacy: .public)")
            p.play { [weak self] in
                // AVMIDIPlayer calls this off the main thread; hop back and drop if superseded.
                Task { @MainActor [weak self] in self?.finished(token: token) }
            }
        } catch {
            log.error(
                "music load failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            player = nil
        }
    }

    private func finished(token: Int) {
        guard token == generation else { return }  // a stop/pause/new-play happened after this one started
        if looping, let current {
            let url = musicDirectory.appendingPathComponent(Self.filename(file: current.file, song: current.song))
            start(url: url, from: nil)
        } else {
            onFinished?()
        }
    }
}
