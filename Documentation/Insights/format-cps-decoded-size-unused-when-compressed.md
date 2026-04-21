# CPS `decodedSize` is only consulted for uncompressed images

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Cps/CpsImage.swift`
- **Category**: format
- **Applies to**: `Formats.Cps.Image`.

## The fact

A CPS header at `[4..7]` is a u32 LE "decoded size". OpenDUNE reads it only in the uncompressed (`0x0000`) path — for the Format80-compressed (`0x0004`) path, the field is ignored and the decoder is called with a generous upper bound (`0xFFFF`). In the real shipped data the field does happen to hold `0x0000FA00 = 64000` for both, but no code enforces that.

## Why it matters

If you treat the u32 as "always the true decoded size," you risk feeding `Codec.Format80` a capacity that's smaller than the image the stream actually produces. 64000 is the correct, file-format-independent constant for CPS (always 320×200 at 1 byte per pixel).

## Where it lives in our code

- `Formats.Cps.decode` — passes `decodedSize` through to `Codec.Format80.decode`. That value happens to equal 64000, but the test suite also covers a short-literal stream that under-fills to prove the clamp works.
- `Tests/DuneIICoreTests/CpsTests.swift::format80Compressed` uses the field; `Format80Tests.swift::clampedToCapacity` nails down the clamp.

## Where it lives in the reference

OpenDUNE `src/sprites.c::Sprites_Decode` — note the `case 0x4` branch never reads the u32 at `source + 2`.
