import DuneIIContracts
import Foundation

/// Chooses *which* song plays *when* — a faithful transcription of OpenDUNE's music-selection logic
/// (`Music_Play`/`g_table_musics` in `src/audio/sound.c` + `src/table/sound.c`; the per-house win/lose/
/// briefing IDs in `src/table/houseinfo.c`; the in-game pick-a-track calls in `src/opendune.c`/`mentat.c`).
///
/// It is the **policy** over a `MusicPlayer` (the mechanism). Track *selection* uses an injected RNG — the
/// host-side analogue of OpenDUNE's GUI `Tools_RandomLCG_Range`, deliberately separate from the simulation's
/// deterministic RNG (music is presentation, not part of the sim contract). Tests inject a seeded RNG.
///
/// The in-game battle/ambient switch is event-driven (the host calls `enterBattle()` off its existing
/// "under attack" signal, and a finished track calls back into `advanceAmbient()`) rather than OpenDUNE's
/// `g_musicInBattle` + 300-tick polling loop — a faithful-in-spirit approximation, not bit-parity.
@MainActor
public final class MusicDirector {
    /// OpenDUNE `g_table_musics` (`src/table/sound.c`): musicID → `(file, song)`, indexed by musicID.
    /// Entry 0 is silence. `<file>` is the `dune<N>` number; `<song>` the XMI sequence index. (Verbatim —
    /// including IDs 27/33–37, which are intro/cutscene-only and unused here.)
    static let table: [(file: Int, song: Int)?] = [
        nil,        /*  0 silence       */
        (1, 2),     /*  1 */ (1, 3),  /*  2 */ (1, 4),  /*  3 */ (1, 5),  /*  4 */
        (17, 4),    /*  5 win Ordos/Fremen */ (8, 3),  /*  6 win Hark/Sard */ (8, 2),  /*  7 win Atr/Merc */
        (1, 6),     /*  8 */ (2, 6),  /*  9 */ (3, 6),  /* 10 */ (4, 6),  /* 11 */ (5, 6),  /* 12 */ (6, 6),  /* 13 */
        (9, 4),     /* 14 */ (9, 5),  /* 15 */ (18, 6), /* 16 */
        (10, 7),    /* 17 */ (11, 7), /* 18 */ (12, 7), /* 19 */ (13, 7), /* 20 */ (14, 7), /* 21 */ (15, 7), /* 22 */
        (1, 8),     /* 23 */
        (7, 2),     /* 24 briefing Hark */ (7, 3),  /* 25 briefing Atr */ (7, 4),  /* 26 briefing Ordos */
        (0, 2),     /* 27 */ (7, 6),  /* 28 */ (16, 7), /* 29 */
        (19, 4),    /* 30 */ (19, 2), /* 31 */ (19, 3), /* 32 */ (20, 2), /* 33 */ (16, 8), /* 34 */
        (0, 3),     /* 35 */ (0, 4),  /* 36 */ (0, 5),  /* 37 */
    ]

    /// Per-house music IDs (`src/table/houseinfo.c`), indexed by `HouseID.rawValue` (Harkonnen…Mercenary).
    /// `0xFFFF` (Fremen/Sardaukar/Mercenary briefing) = none.
    static let briefingMusic = [24, 25, 26, 0xFFFF, 0xFFFF, 0xFFFF]
    static let winMusic       = [6, 7, 5, 5, 6, 7]
    static let loseMusic      = [3, 4, 2, 2, 3, 4]

    static let mapTracks = 8 ... 15      // in-mission ambient pool (Tools_RandomLCG_Range(0,8)+8)
    static let attackTracks = 17 ... 22  // in-battle pool (Tools_RandomLCG_Range(0,5)+17)

    private let musicDirectory: URL
    private let soundBank: URL?
    private var player: MusicEngine
    private var rng: any RandomNumberGenerator
    public private(set) var currentMusicID = 0
    private var currentLoop = false
    /// Master gate. Off ⇒ every entry point is a no-op and nothing ever plays (the neutrality toggle).
    public var enabled = true { didSet { if !enabled { player.stop() } } }

    /// The synthesis backend. Swapping it live stops the current engine, builds the other, and resumes the
    /// track that was playing — so the user hears the same song in the new timbre without a gap in the policy.
    public var backend: MusicBackend { didSet { if backend != oldValue { switchEngine() } } }

    public init(musicDirectory: URL,
                soundBank: URL? = nil,
                backend: MusicBackend = .adlib,
                rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.musicDirectory = musicDirectory
        self.soundBank = soundBank
        self.backend = backend
        self.rng = rng
        self.player = Self.makeEngine(backend, musicDirectory: musicDirectory, soundBank: soundBank)
        // A finished ambient/attack track rolls into the next random map theme, so music never falls silent.
        player.onFinished = { [weak self] in self?.advanceAmbient() }
    }

    private static func makeEngine(_ backend: MusicBackend, musicDirectory: URL, soundBank: URL?) -> MusicEngine {
        switch backend {
        case .adlib: ADLMusicPlayer(musicDirectory: musicDirectory)
        case .midi: MusicPlayer(musicDirectory: musicDirectory, soundBank: soundBank)
        }
    }

    private func switchEngine() {
        player.stop()
        player = Self.makeEngine(backend, musicDirectory: musicDirectory, soundBank: soundBank)
        player.onFinished = { [weak self] in self?.advanceAmbient() }
        // Resume whatever was playing in the new timbre (no-op when nothing was, or when music is disabled).
        if enabled, currentMusicID > 0, let track = Self.table[currentMusicID] {
            player.play(file: track.file, song: track.song, loop: currentLoop)
        }
    }

    /// `Music_Play` core: resolve a musicID to its track and start it. Invalid/none (`0xFFFF`, out-of-range,
    /// or the silence entry) stops playback. Unlike OpenDUNE we don't short-circuit a repeat of the current
    /// ID — our callers are discrete events, not a polling loop.
    @discardableResult
    public func play(musicID: Int, loop: Bool) -> Bool {
        guard enabled else { return false }
        guard musicID > 0, musicID < Self.table.count, let track = Self.table[musicID] else {
            currentMusicID = 0
            player.stop()
            return false
        }
        currentMusicID = musicID
        currentLoop = loop
        player.play(file: track.file, song: track.song, loop: loop)
        return true
    }

    /// Mission start / return-to-ambient: a random map theme (musicID 8–15), played once so it rolls into a
    /// fresh pick at its end.
    public func startInGame() { playRandom(in: Self.mapTracks) }
    public func advanceAmbient() { playRandom(in: Self.mapTracks) }

    /// Enemy attacking the player: switch to a random attack theme (17–22). Returns to ambient when it ends.
    public func enterBattle() { playRandom(in: Self.attackTracks) }

    /// End-of-mission stingers (held, i.e. looped) — per the player's house.
    public func win(house: HouseID) { play(musicID: Self.winMusic[house.rawValue], loop: true) }
    public func lose(house: HouseID) { play(musicID: Self.loseMusic[house.rawValue], loop: true) }

    public func pause() { player.pause() }
    public func resume() { player.resume() }
    public func stop() { currentMusicID = 0; player.stop() }

    private func playRandom(in range: ClosedRange<Int>) {
        guard enabled else { return }
        // Manual range-reduce off the RNG's raw word (not `Int.random(in:using:)`, which can't take an
        // `any RandomNumberGenerator` inout) — selection bias is irrelevant for picking a music track.
        let pick = range.lowerBound + Int(rng.next() % UInt64(range.count))
        play(musicID: pick, loop: false)
    }
}
