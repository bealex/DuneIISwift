# Music

In-game music for the `duneii` client. Two interchangeable backends play the **same** OpenDUNE song selection (`MusicDirector` — unchanged), differing only in *how* they synthesise it:

- **AdLib FM (OPL3)** — the default. The Westwood `.ADL` files synthesised on an emulated OPL3 chip, exactly as the DOS AdLib hardware did. Authentic timbre. See `Music.OPL2.md` (the design) + `ADLMusicPlayer`.
- **MIDI (SoundFont)** — the original route: the extracted Standard-MIDI songs through `AVMIDIPlayer` + a SoundFont/DLS bank. `MusicPlayer`, documented below.

The two share the `MusicEngine` protocol seam (`Code/Frameworks/DuneIIAudio/MusicEngine.swift`); `MusicDirector.backend` swaps between them live (Settings ⌘, → Audio → "Music engine"), stopping the current engine, building the other, and resuming the playing track in the new timbre. The choice is persisted (`UserDefaults` key `musicBackend`, default `.adlib`).

## Synth path — `AVMIDIPlayer`

macOS ships a complete MIDI sequencer + synthesiser in AVFoundation: `AVMIDIPlayer(contentsOf:soundBankURL:)` plays a Standard-MIDI file through a SoundFont/DLS bank. This is the same role OpenDUNE delegates to FluidSynth/MUNT (`src/audio/midi_fluid.c`); it is **not** an OPL2/AdLib chip emulation — and neither is OpenDUNE's path, so a SoundFont synth actually mirrors the oracle rather than diverging from it.

- `soundBankURL == nil` ⇒ the system's built-in **General-MIDI DLS** bank (a GM approximation of the original AdLib voices). This is what ships today.
- Pass a `.sf2`/`.dls` for closer timbre. The client looks for a bundled/repo `Resources/Audio/music.sf2` and uses it automatically if present (`GameModel.soundBankURL()`), so a better bank is a drop-in with no code change.

`MusicPlayer` (`Code/Frameworks/DuneIIAudio/MusicPlayer.swift`) is the mechanism: `play(file:song:loop:)`, `stop`, `pause`/`resume`. `AVMIDIPlayer` has no cancel for its completion callback, so each (re)start/stop/pause bumps a `generation` token and a stale callback is dropped. `pause` remembers `currentPosition` and `resume` seeks back to it.

## Songs — the extracted MIDI, and why no XMI decoder is needed

`Resources/Audio/Music/` holds 842 Standard-MIDI Format-0 files named `DUNE<file>.<song:02d>.mid`. The raw XMI containers (`.ADL` AdLib, `.C55` MT-32, `.PCS` PC-speaker, `.TAN` Tandy — FORM/XDIR/CAT, ~70 sequences each) are committed alongside them.

The key finding: the `.NN` suffix **is the XMI sequence index**, which is exactly the index OpenDUNE's `g_table_musics` uses. Every `(file, song)` pair the game selects in-mission resolves to an existing file; the only absent ones (dune0 songs 3/5) are intro/cutscene-only — content we deliberately omit. So the selection table can be transcribed directly against the existing files; **no XMI→MIDI decoder is required.**

> Known gap (out of scope here): these `.mid` were produced by an external tool, so `assetgen` cannot currently regenerate them — they're committed as-is. A future Formats XMI decoder (oracle: `src/audio/mt32mpu.c`) would let `assetgen` own them.
>
> **Authentic AdLib timbre is a separate, larger route** that does *not* go through these MIDI files — it synthesises the Westwood `.ADL` files on an emulated OPL2 chip. See **`Music.OPL2.md`** for the full investigation/design (Tier C).

## Selection — `MusicDirector`

`MusicDirector` (`Code/Frameworks/DuneIIAudio/MusicDirector.swift`) is the policy — a faithful transcription of OpenDUNE's selection logic:

- `table` = `g_table_musics` verbatim (`src/table/sound.c`): musicID → `(file, song)`, 38 entries, index 0 = silence.
- `winMusic` / `loseMusic` / `briefingMusic` = the per-house IDs from `g_table_houseInfo` (`src/table/houseinfo.c`), indexed by `HouseID.rawValue`. `0xFFFF` = none (Fremen/Sardaukar/Mercenary briefing).
- Pools: map/ambient = musicID `8…15` (`Tools_RandomLCG_Range(0,8)+8`); attack = `17…22` (`+17`); per-house win/lose stingers.
- `play(musicID:loop:)` is the `Music_Play` core (invalid/none ⇒ stop).

Track *selection* uses an injected RNG — the host-side analogue of OpenDUNE's GUI `Tools_RandomLCG_Range`, deliberately **separate from the simulation's deterministic RNG**. Music is presentation; it never reads or mutates `GameState`, never draws sim RNG, and real-time playback is outside the deterministic-sim contract.

## Host wiring (`GameModel`)

| Event | Hook (`Code/Apps/duneii/GameModel.swift`) | Music |
|---|---|---|
| Scenario/save loaded | `finishLoad` | `startInGame()` — random map theme, rolling into the next at its end |
| Player base under attack | the existing "under attack" edge in `refreshHints` | `enterBattle()` — random attack theme, then back to ambient |
| Win / Lose latched | `refreshDerived` (`gameEndState` change) | `win/lose(house:)` stinger |
| Pause toggled | `paused` `didSet` | `pause()` / `resume()` |
| Master toggle | `musicEnabled` | gates everything (`MusicDirector.enabled`) |

The battle/ambient switch is **event-driven** off the host's existing combat signal rather than OpenDUNE's `g_musicInBattle` + 300-tick polling loop — a faithful-in-spirit approximation, **not** bit-parity (and it needs no new sim coupling).

## Fidelity caveats (honest list)

- **Timbre is GM/DLS**, not AdLib FM, until a `.sf2` is dropped in. Melody/tempo/structure are the original songs.
- **Track cycling is a host heuristic**, not OpenDUNE's exact `g_musicInBattle` state machine.
- **Non-deterministic** by design (real-time playback, host RNG).
- **Menus/briefing screens stay omitted** — `briefingMusic` is transcribed and tested for completeness but isn't triggered (we render no Mentat screen).

## Testing

No OpenDUNE oracle exists at the audio-output level, so the golden bar is a **flag-off neutrality golden**: music is entirely host-side and touches no sim state, so every existing scenario and render golden stays byte-identical (verified by the full suite staying green). Plus unit coverage in `Code/Tests/AudioTests/MusicDirectorTests.swift`: the table is verbatim, the per-house IDs match, the filename mapping is right, the random pools land in range (seeded RNG), and **every selectable track resolves to a real file on disk** (short-circuits when assets are absent).

### Manual verification checklist (audio output can't be unit-tested)

Run `swift run duneii` from `Code/`, then:

1. Load a scenario → a map theme plays and, at its end, rolls into another map theme (no silence).
2. Let an enemy attack your base → music switches to a faster attack theme, then returns to ambient.
3. Win or lose a mission → the house victory/defeat stinger plays (and holds while the end banner is up).
4. Press pause → music pauses; unpause → it resumes from where it stopped.
5. Drop a `Resources/Audio/music.sf2` in and relaunch → timbre changes to that bank.
