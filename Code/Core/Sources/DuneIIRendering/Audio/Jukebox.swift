import Foundation
@preconcurrency import AVFoundation

/// Thin wrapper around `AVMIDIPlayer` that plays Dune II's XMI music.
/// One active player at a time — replacing the current song stops the
/// previous one. Lives on `@MainActor` because AVMIDIPlayer isn't
/// documented as thread-safe and the scene layer only calls us from the
/// main actor anyway.
///
/// When `soundBankURL` is nil, AVMIDIPlayer falls back to the system
/// default `DLSMusicDevice` (Apple-supplied GM sound bank). Drop a user
/// SoundFont at `~/Library/Audio/Sounds/Banks/` or point
/// `init(soundBankURL:)` at any `.sf2` / `.dls` to override.
@MainActor
public final class Jukebox {
    public let loader: AssetLoader
    public let soundBankURL: URL?

    private var current: AVMIDIPlayer?

    public init(loader: AssetLoader, soundBankURL: URL? = nil) {
        self.loader = loader
        self.soundBankURL = soundBankURL
    }

    /// Stops whatever is currently playing. Safe to call when nothing
    /// is active.
    public func stop() {
        current?.stop()
        current = nil
    }

    /// Loads `<name>` (e.g. `"DUNE0.XMI"`) from the install, converts
    /// track 0 to SMF, and begins playback. Replaces any previous song.
    /// Throws when the asset is missing or the MIDI file can't be built.
    @discardableResult
    public func play(named name: String) throws -> Bool {
        guard let smf = try loader.loadXmiAsSMF(named: name) else {
            return false
        }
        return try play(smfData: smf)
    }

    /// Direct path for tests — play a pre-baked SMF byte stream.
    @discardableResult
    public func play(smfData: Data) throws -> Bool {
        stop()
        let player = try AVMIDIPlayer(data: smfData, soundBankURL: soundBankURL)
        player.prepareToPlay()
        player.play(nil)
        current = player
        return true
    }

    /// Whether a song is currently playing. Useful for tests / scene
    /// guards; does NOT reflect "song reached end" — AVMIDIPlayer does
    /// not expose that without the completion callback.
    public var isPlaying: Bool {
        current?.isPlaying ?? false
    }
}
