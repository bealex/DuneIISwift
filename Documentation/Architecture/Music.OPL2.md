# Music — authentic AdLib OPL2/OPL3 FM synthesis (Tier C investigation)

**Status: investigation / design only. Not implemented.** This is the decision doc for the "authentic AdLib" route — the timbre-faithful alternative to the shipped SoundFont path (`Music.md`). Read `Music.md` first; this picks up where its "fidelity caveats" leave off.

## 1. Why this exists

The shipped music (`Music.md`, Tier B) plays through `AVMIDIPlayer` + a SoundFont. It gets the melodies right but **not the timbre**: it renders *General-MIDI program numbers* with sampled instruments. Two compounding reasons it can never sound like the DOS original:

1. The extracted `.mid` come from the **`.C55` (XMIDI / MT-32-GM) variant** — they only ever carried GM program-change events. The original AdLib FM patch data was never in them.
2. Even a GM SoundFont that *mimics* FM (e.g. `OPL-3_FM_128M.sf2`) still plays the GM program mapping, not the game's actual per-voice OPL operator settings.

Authentic AdLib means going back to the **`.ADL` files** and synthesising them on an emulated OPL2 chip — exactly what the DOS game did. This is a real "synth + sequencer port," and unlike the SoundFont route it is **not** something macOS gives us for free.

## 2. Key finding — the `.ADL` files are Westwood's own format, not XMIDI

This reframes everything. The raw music files per sound device are:

| File | Format | Synth target | What we did with it |
|---|---|---|---|
| `DUNEn.ADL` | **Westwood ADL** (`00 01 02 FF …`) | **OPL2 (AdLib)** | untouched — this is the Tier-C source |
| `DUNEn.C55` | XMIDI (`FORM…XDIR…CAT`) | MT-32 / GM | the shipped `.mid` were extracted from this |
| `DUNEn.PCS` | XMIDI | PC speaker | unused |
| `DUNEn.TAN` | XMIDI | Tandy | unused |

The `.ADL` is **not** MIDI at all. It is the **Westwood ADL driver format** (confirmed: header `00 01 02 FF…`, an offset/pointer table, no `FORM/XMID` chunks). Per the format references (shikadi ModdingWiki; VGMPF), Dune II uses the **"version 2"** ADL format — the same one in *The Legend of Kyrandia* and *Eye of the Beholder II* (the version-2 track-pointer array is 300 bytes). Critically:

- **Instruments are embedded.** ADL "stores audio and instrument definitions in the same file" — the FM operator/register values live inside `DUNEn.ADL`. There is **no external timbre bank to find** (unlike the Miles/AIL `.AD`/`.OPL` global-timbre-library games). Self-contained.
- The file is effectively a **little bytecode program**: a per-channel sequencer interpreter (~70 driver opcodes) whose net effect is timed writes to the OPL2 register set, plus an instrument table the programs load operators from.

**Consequence:** Tier C is **not** "decode XMI → MIDI." It is "port the Westwood ADL driver + an OPL2 chip." The existing `.mid` and `MusicDirector` selection table are irrelevant to the *synthesis*; only the **song-index selection** carries over (see §7).

## 3. Architecture — two components + a sink tap

```
DUNEn.ADL ──► [Westwood ADL player]  ──timed OPL register writes──►  [OPL2 emulator]  ──PCM──►  [AVAudioEngine source node]  ──► mixer
            (bytecode interpreter,                                  (register file →
             ~70 opcodes, embedded                                  FM operators →
             instruments, channel state)                            sample stream)
```

1. **OPL2/OPL3 chip emulator** — a pure function of (register writes over time) → a stream of PCM samples (typically rendered at the chip's native rate, then resampled to our 22 050 Hz / 44 100 Hz output). This is stable, game-agnostic, well-trodden DSP.
2. **Westwood ADL player** — the game-specific bytecode interpreter. Reads `DUNEn.ADL`, runs the selected track's program at the driver's tick rate, and emits register writes to (1). This is where all the Dune-II-specific behaviour lives.
3. **Sink integration** — feed the emulator's PCM into our existing `AVAudioEngine` graph as a source node (an `AVAudioSourceNode` render callback, or scheduled buffers on a player node). The `MusicDirector` selection policy (`Music.md`) is reused verbatim; only the *backend* changes from `AVMIDIPlayer` to this OPL player. A `MusicBackend` seam (`.midi` vs `.adlib`) lets both coexist and be A/B'd.

## 4. The OPL core — options, accuracy, licensing

Vendoring a small C core is the realistic choice here (see §6); pure-Swift transcription of the DSP is possible but high-risk to get bit-exact by hand.

| Core | Lang | Accuracy | License | Notes |
|---|---|---|---|---|
| **Nuked-OPL3** | C (1 file, ~2 kloc) | **Bit-perfect** vs real YMF262 | **LGPL-2.1+** | The gold standard. No floating point. Heavier CPU (irrelevant for one music voice). OPL3 superset plays OPL2 content. **Recommended core.** |
| DOSBox **dbopl** | C++ | Very good, fast | GPL-2.0+ | What Dune Dynasty ships (`opl_dosbox.cpp`). GPL is stickier than LGPL. |
| **MAME** YM3812 | C++ | Good | GPL/BSD-ish (MAME) | Dune Dynasty also ships `opl_mame.cpp` as an alt. |
| Ken Silverman `adlibemu` | C | Approximate | Public-domain-ish | Tiny, permissive, but least accurate. |

**Recommendation: Nuked-OPL3**, vendored unmodified as a SwiftPM **C target** (`COpl`), called from Swift. LGPL on an *unmodified, separable* C library is clean to comply with (it stays a distinct, attributed component); accuracy is the whole point of choosing Tier C, so take the best core.

## 5. The Westwood ADL player — references

The driver is ~2 700 lines of fiddly state machine. Do **not** write it from scratch — there are several faithful open implementations to transcribe/verify against:

- **Dune Dynasty** — `src/audio/adl/sound_adlib.cpp` (+ `opl_dosbox.cpp` / `opl_mame.cpp` / `fmopl.cpp`). **A working Dune II remaster that runs on macOS and plays this exact music.** This is the single best reference: it is *this game*, already wired core→player→cross-platform audio. (License: carries both GPL-2 and LGPL-2.1 notices — it's the ScummVM driver; see §8.)
- **ScummVM** — `engines/kyra/sound/drivers/adlib.cpp` (the upstream of the above) + `audio/fmopl.*`. The canonical, maintained Westwood-ADL driver; handles ADL versions 1/2/3 (Dune II = v2). GPL-2.
- **AdPlug** — `src/adl.cpp` (`CadlPlayer`). An **LGPL-2.1** Westwood-ADL player; the more license-friendly reference if we want to stay clear of GPL.
- **NScumm.Audio** — `github.com/scemino/NScumm.Audio`, a **C#** AdLib player that explicitly lists Dune II. A managed-language port is the closest idiom to a Swift transcription — invaluable as a "what does this look like without C pointer tricks" cross-check.
- **Format spec:** shikadi ModdingWiki "ADL Format"; VGMPF "ADL (Westwood)".

## 6. Two implementation strategies

**(A) Pure-Swift transcription of both** (ADL player + OPL core). Most consistent with the project's "Foundation-only Swift transcription" ethos and bit-exact-able end to end. But it's ~2 700 (player) + ~2 000 (OPL) ≈ **~4 700 lines of hand-ported, hard-to-eyeball fixed-point DSP + bytecode**. The OPL core especially is a verification nightmare to hand-confirm.

**(B) Vendor the OPL core in C, transcribe only the ADL player to Swift.** *(Recommended.)* Vendor **Nuked-OPL3** as an unmodified `COpl` C target (a commodity, exhaustively tested upstream, treated as a black box behind a tiny Swift wrapper). Transcribe only the **~2 700-line Westwood ADL player** to Swift — the part that is game-specific, interesting, and exactly the kind of "exact transcription of a reference C driver" the project already does for OpenDUNE. This roughly halves the hand-port and isolates it to the part we can actually verify by trace (§9). Mirrors Dune Dynasty's own split.

This doc recommends **(B)**.

## 7. Data path & song selection

- **Source bytes:** the `.ADL` are already in `Resources/Audio/Music/DUNEn.ADL` (and in the install's `SOUND.PAK`). The player consumes the whole file; **no per-format decoder in `DuneIIFormats` is needed** — the ADL player *is* the consumer. (If we want a `DuneIIFormats/ADL` parse step for the header/track table, it's optional structuring, not required.)
- **Selection:** OpenDUNE's `g_table_musics` gives `(fileIndex, songIndex)`. The original engine uses **one logical song index across all device drivers** — `Driver_Music_Play(index)` selects track `index` whether the loaded file is `.ADL` or `.C55`. So **`MusicDirector`'s table maps to the ADL track number unchanged**: load `DUNE<file>.ADL`, play its track `song`. ⚠️ **Verify** that the ADL track table's indexing matches the XMIDI sequence index 1:1 (very likely, but confirm against ScummVM/Dune Dynasty before trusting it).
- **Looping / battle/ambient cycling:** identical to `Music.md` — the OPL player exposes "is finished" the same way, so the `MusicDirector` event model is untouched.

## 8. Licensing — the main review question

Every faithful ADL-player reference is **GPL-2 (ScummVM, Dune Dynasty, DOSBox) or LGPL-2.1 (AdPlug, Nuked-OPL3)**. Two things to decide:

1. **Transcription provenance.** The project *already* transcribes GPL-2 OpenDUNE into Swift as its core methodology (citing `src/file.c:line`). The ADL player would follow the same pattern. If transcribing GPL C into Swift makes the result a derivative work, that obligation **already exists** for the whole simulation — Tier C doesn't introduce a *new* category of risk, but it's worth an explicit decision. To minimise exposure, **prefer the LGPL AdPlug `CadlPlayer` + the C# NScumm.Audio as the transcription references** over the GPL ScummVM/Dune Dynasty copies (use the GPL ones only as behavioural oracles for trace-diffing, §9).
2. **Vendored core.** Nuked-OPL3 (LGPL-2.1) shipped **unmodified** as a separable C target with its license file retained is the cleanest compliance story (it remains an identifiable, attributed library; we are a user of it, not a derivative of it).

**Recommendation for review:** decide whether the repo is comfortable (a) continuing GPL-reference *transcription* for the player — ideally narrowed to LGPL references — and (b) vendoring one LGPL C core with attribution. If GPL transcription is unacceptable, Tier C is effectively blocked (there is no permissive Westwood-ADL implementation), and Tier B (SoundFont) remains the ceiling.

## 9. Verification — the parity bar

This is the project's strength and it transfers cleanly:

- **OPL register-write trace equivalence (the behavioural-parity analog).** Our Swift ADL player should emit the **same timed sequence of `(register, value)` writes** as the reference player for a given `.ADL` track. Dump both streams (ours; ScummVM/Dune Dynasty instrumented to log register writes) and diff by index — exactly the EMC decision-trace methodology, applied to audio, and it **isolates the player from the OPL core** (a divergence is a player bug, not a DSP rounding difference). This is the primary golden.
- **OPL core unit vectors.** The vendored Nuked-OPL3 is verified upstream; add a thin SwiftPM C-target test feeding a known register script and checking a few output samples against captured reference values (guards the build/wiring, not the algorithm).
- **PCM render golden (optional, fuzzy).** Render a fixed `.ADL` track for N ms to PCM and compare against a reference WAV from Dune Dynasty/AdPlug. With the *same* OPL core this can be near-exact; across cores expect small numeric drift, so gate on a tolerance or a spectral check, not byte-equality.
- **Neutrality.** Like Tier B, this is host-side and touches no sim state — all existing scenario/render goldens stay byte-identical.

## 10. Effort, risk, and a phased plan

**Effort: large** — the biggest single presentation feature remaining. Rough phases (each its own commit/golden):

1. **Vendor + wire the OPL core.** Add the `COpl` C target (Nuked-OPL3 + license), a minimal Swift wrapper (`reset / write(reg,val) / render(into:)`), and a C-target smoke test. *(Small, mechanical, de-risks the build/SwiftPM-C-interop question first.)*
2. **`.ADL` structure parse.** Read the version-2 header, instrument table, and per-track program offsets; a `DuneIIFormats`-style test dumping the track table for `DUNE0.ADL` and asserting it against a known-good reference.
3. **ADL player core.** Transcribe the channel/sequencer state machine + the ~70 driver opcodes. Verify by **register-write trace diff** (§9) against the reference, one track at a time, until the stream matches.
4. **Sink integration + backend seam.** An `AVAudioSourceNode` render callback pulling from the OPL emulator; a `MusicBackend` protocol so `MusicDirector` drives either `.midi` or `.adlib`; a settings toggle (Built-in DLS / SoundFont / **AdLib FM**).
5. **Polish:** resampling quality, per-track loop points, volume, pause via the source node.

**Risks / open questions for review:**
- **Licensing (§8)** — the gating decision. Resolve before any code.
- **ADL version & opcode coverage** — confirm Dune II is exactly ScummVM "version 2" and that no Dune-specific opcode quirk exists (EOB2/Kyra1 share it, so low risk).
- **Song-index ↔ ADL-track mapping (§7)** — verify 1:1 with the XMIDI index.
- **Render-callback realtime safety** — the OPL render must be allocation-free on the audio thread; Nuked is, but the Swift wrapper must not allocate per callback.
- **Is it worth it?** Tier B already plays the music. Tier C buys *authentic timbre* only — a connoisseur feature. Scope it as opt-in (a third backend), never a regression of the working SoundFont path.

## 11. One-paragraph recommendation

If timbre authenticity is wanted: go **(B)** — vendor **Nuked-OPL3** (LGPL, unmodified C target) and transcribe the **Westwood ADL "version 2" player** to Swift, using **AdPlug's `CadlPlayer` (LGPL) + NScumm.Audio (C#)** as the transcription references and **Dune Dynasty / ScummVM** as behavioural oracles for **register-write trace diffing**. Reuse the `Music.md` `MusicDirector` selection unchanged behind a new `MusicBackend` seam; ship it as an opt-in "AdLib FM" backend alongside the existing SoundFont path. The single blocking decision is **licensing (§8)** — settle that first; everything else is a tractable, well-referenced port with a clean trace-based parity bar.

---

### References
- Dune Dynasty (working Dune II remaster, macOS) — `github.com/gameflorist/dunedynasty`, `src/audio/adl/`
- ScummVM Kyra AdLib driver — `engines/kyra/sound/drivers/adlib.cpp`; OPL frontend `audio/fmopl.*`
- AdPlug `CadlPlayer` (LGPL Westwood-ADL player) — `src/adl.cpp`
- NScumm.Audio (C# AdLib player, lists Dune II) — `github.com/scemino/NScumm.Audio`
- Nuked-OPL3 (LGPL-2.1, bit-perfect OPL3) — `github.com/nukeykt/Nuked-OPL3`
- ADL format spec — shikadi ModdingWiki "ADL Format"; VGMPF "ADL (Westwood)"
- OPL emulator survey/licenses — DoomWiki "OPL emulation"
