# VOC sample rate = `1_000_000 / (256 - divisor)`

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Voc/VocSound.swift`
- **Category**: audio
- **Applies to**: `Formats.Voc.Sound`, the AVAudioEngine playback path in the future `Audio/` module.

## The fact

The first byte of a VOC type-1 block body is a rate *divisor*, not a sample rate. The actual Hz is:

```
sampleRate = 1_000_000 / (256 - divisor)
```

Dune II ships `divisor = 131` (→ 8000 Hz), `divisor = 165` (→ ~10989 Hz), and a handful of oddities — `divisor = 192` → 15625 Hz etc. None are common modern rates, which is why playback invariably needs a resampler.

## Why it matters

Treating the divisor as a raw sample rate produces grossly time-compressed audio (every sample plays for `1 / 131` second). Conversely, treating it as a sample rate in Hz gives a speed-of-light delivery that sounds like a chipmunk on amphetamines.

## Where it lives in our code

- `Formats.Voc.decode` — applies the formula once per file.
- `Tests/DuneIICoreTests/VocTests.swift::synthetic` uses `divisor = 131` and asserts exactly `8000` comes out.

## Where it lives in the reference

OpenDUNE `src/audio/dsp_sdl.c::DSP_Play`:

```c
DSP_ConvertAudio(1000000 / (256 - data[4]));
```

where `data[4]` is the divisor byte of the type-1 block.
