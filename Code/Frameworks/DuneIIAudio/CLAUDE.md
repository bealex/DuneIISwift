# DuneIIAudio

Audio — the `sim → audio` driver. Depends only on `DuneIIContracts` (the `SoundEvent` vocabulary). Never depends on the simulation. `@MainActor` (a UI-side presentation leaf driven from the host's main thread).

The host registers each sound's PCM under a `SoundID` once, then plays `SoundEvent`s; the sink never reads simulation state — it only consumes events the host hands it.

Present (first version):
- **`AudioSink`** protocol — `register(_:sampleRate:pcm8:)` (pre-decode a sound, so a later play has no load latency), `play(_:)`, `stopAll()`. `pcm8` is unsigned 8-bit mono PCM (the VOC sample format).
- **`NullAudio`** — no-op (headless / tests / audio off).
- **`EngineAudioSink`** — the real one (`AVAudioEngine`). **Low-latency + polyphonic**: sounds are pre-decoded into `AVAudioPCMBuffer`s (all resampled to one canonical float32-mono rate, so any buffer plays on any node), and a **pool of player nodes** is kept running, so `play` is a single `scheduleBuffer(at: nil, options: .interrupts)` — it starts at the next render quantum (no perceptible delay) and **mixes** with other voices. Voices are handed out round-robin; only with more than `voices` overlapping sounds does a new one steal the oldest. No audio output device (`start()` throws on a CI box) → it degrades to silent (`play` no-ops). Resampling is manual linear interpolation (adequate for these low-fi samples; avoids `AVAudioConverter`'s `@Sendable` input-block).

The host (`mapview`) decodes install VOCs (`Voc.decode`), registers them, starts the engine, and plays a feedback sound on each player action. Tests: `AudioTests` (the 8-bit→float conversion, buffer building + resample, `NullAudio`, graceful no-device).

To come: distance attenuation from `SoundEvent.position`, the sim emitting `SoundEvent`s for its ~10 inline sound sites (currently SEAMs), and music. See `Documentation/Plan.v1.md` §4 (Phase 7).
