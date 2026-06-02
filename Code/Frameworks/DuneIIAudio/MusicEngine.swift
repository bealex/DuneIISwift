import Foundation

/// Which synthesis backend plays the music. Both render the **same** `(file, song)` selection (the OpenDUNE
/// `g_table_musics` index — see `MusicDirector`); only the timbre differs.
public enum MusicBackend: String, CaseIterable, Sendable {
    /// The DOS AdLib FM sound — the Westwood `.ADL` files synthesised on an emulated OPL3 chip (SwiftOPL3 +
    /// WestwoodADL). Authentic timbre. See `ADLMusicPlayer` and `Documentation/Architecture/Music.OPL2.md`.
    case adlib
    /// The extracted Standard-MIDI songs through `AVMIDIPlayer` + a SoundFont/DLS bank. See `MusicPlayer`.
    case midi

    public var displayName: String {
        switch self {
        case .adlib: "AdLib FM (OPL3)"
        case .midi: "MIDI (SoundFont)"
        }
    }
}

/// The playback *mechanism* a `MusicDirector` drives — the seam that lets the `.adlib` (`ADLMusicPlayer`) and
/// `.midi` (`MusicPlayer`) backends be swapped live behind the unchanged selection policy. A `(file, song)`
/// pair is the OpenDUNE music index; each backend resolves it to its own on-disk asset (`DUNE<file>.ADL`
/// subsong `song` for AdLib, `DUNE<file>.<song:02d>.mid` for MIDI).
@MainActor
public protocol MusicEngine: AnyObject {
    /// Fires when a non-looping track plays to its end (and was not stopped/paused). The director uses this to
    /// roll into the next ambient track, so music never falls silent.
    var onFinished: (@MainActor () -> Void)? { get set }

    /// Start the song for `(file, song)`. `loop` restarts/sustains it; otherwise `onFinished` fires at the end.
    func play(file: Int, song: Int, loop: Bool)
    func stop()
    /// Freeze playback, remembering the position so `resume()` continues seamlessly.
    func pause()
    func resume()
}
