# VOC — Creative Voice file

Status: Documented 2026-04-19

VOC is the original Creative Labs Sound Blaster audio format. Dune II only ever uses the simplest form — one or two type-1 blocks of unsigned 8-bit mono PCM — so we decode that subset and reject anything else.

References:

- OpenDUNE `src/audio/dsp_sdl.c` · `DSP_Play` reads exactly the header + first block.
- Our decoder: `Formats.Voc.Sound` in `Code/Core/Sources/DuneIICore/Formats/Voc/`.

## 1. Layout

```
offset  size  content
0       20    "Creative Voice File" + 0x1A terminator
20      2     dataOffset  u16 LE   (usually 0x001A)
22      2     version     u16 LE   (0x010A or 0x0114)
24      2     checksum    u16 LE
26      …     blocks
```

Each block:

```
u8        type   (0 = end of file)
u24 LE    size   (bytes of block body, follows)
...size bytes of body
```

Block types we handle:

| Type  | Body                                                             |
|-------|------------------------------------------------------------------|
| 0x00  | Terminator. Stop reading.                                        |
| 0x01  | Sound: `[rateDivisor: u8, codec: u8, samples: u8…]`. `codec` must be 0 (unsigned 8-bit PCM). `sampleRate = 1_000_000 / (256 - rateDivisor)`. |
| 0x02  | Continuation of previous type-1 block — samples only, no rate.    |

Every other block type is silently ignored.

## 2. Sample-rate quirk

Dune II's VOCs all land on odd sample rates (e.g. 20000 Hz, 22050 Hz, 16129 Hz). OpenDUNE converts them all to a single playback rate using `SDL_BuildAudioCVT`. We hand the raw rate + samples to AVFoundation and let `AVAudioEngine` resample.

## 3. Swift API

```swift
let data = pak.body(named: "MOVEOUT.VOC")!
let sound = try Formats.Voc.decode(data)
// sound.sampleRate in Hz, sound.samples is mono u8 PCM
```

## 4. Testing

`Core/Tests/DuneIICoreTests/VocTests.swift`:

1. Synthetic minimal VOC round-trips.
2. If `INTROVOC.PAK` or `VOC.PAK` is present, pick the first `*.VOC` entry and assert it decodes to a non-empty sample array with a plausible sample rate (≥ 4000 Hz).
3. Bad magic is rejected.
4. Type-2 continuation block correctly appends to a prior type-1.

## 5. Related insights

- [audio-voc-sample-rate-formula](../Insights/audio-voc-sample-rate-formula.md) — the classic `1_000_000 / (256 − divisor)` rate formula.
