# SHP offset table has `count + 1` entries and the frame header lives at `offset[0] + 2`

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Shp/ShpFrameSet.swift`
- **Category**: format
- **Applies to**: `Formats.Shp.FrameSet`, any future SHP encoder.

## The fact

For the modern (v1.07) SHP layout:

- Bytes `[0..1]` hold `count` (u16).
- Bytes `[2..]` hold **`count + 1` u32 LE offsets**. The final u32 is an end-of-file sentinel.
- `offset[0] == 4 + count * 4`. That value lands inside the last offset entry (its low two bytes).
- Each frame's 10-byte header lives at `offset[i] + 2`; the two skipped bytes are the *high* bytes of the previous offset entry, repurposed as a per-frame prefix.

OpenDUNE's loader uses the heuristic `offset[0] == 4 + count * 4` to detect the modern format (vs the legacy u16-offset variant). For a one-frame file, the test file must therefore emit **two** u32 offsets, not one.

## Why it matters

The first synthetic SHP test wrote one offset and put the frame header directly after it. `offset[0] + 2` landed in uninitialized bytes and the decoder read `height = 0`. Real files worked because they naturally have the terminator u32.

## Where it lives in our code

- `Formats.Shp.decode` — reads offset, adds 2 for modern.
- `Tests/DuneIICoreTests/ShpTests.swift::buildModernShp` — the synthetic builder that now emits `count + 1` offsets.

## Where it lives in the reference

OpenDUNE `src/sprites.c::Sprites_Load`:

```c
uint32 offset = !oldFormat ? READ_LE_UINT32(buffer + 2 + 4 * i) : ...;
const uint8 *src = buffer + offset;
if (!oldFormat) src += 2;
```
