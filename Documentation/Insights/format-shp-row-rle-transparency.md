# After Format80, SHP pixel data is still run-length encoded; `0x00 N` = N transparent pixels

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Shp/ShpFrameSet.swift`
- **Category**: format
- **Applies to**: `Formats.Shp.FrameSet`, any future sprite renderer.

## The fact

The `decodedSize` in a SHP frame header is **not** `width * height`. It's the size of a second-stage RLE stream that the draw routine consumes. In that stream:

- A non-zero byte is a literal palette index (one pixel).
- A `0x00` byte is followed by a count byte `N` — the next N pixels are transparent.

Palette index 0 cannot appear as a literal pixel because 0 is the RLE marker. This is why "index 0 = transparent" is the convention.

## Why it matters

Our first SHP pass asserted `pixels.count == width * height` after the format80 step. Real `UNITS.SHP` frames fail that check — the format80 output is the *RLE stream*, not the final buffer. The fix is a second expansion pass that walks the stream and emits 0 for each transparent pixel, matching the engine's draw loop.

## Where it lives in our code

- `Formats.Shp.expandRowRLE` — does the expansion.
- `Tests/DuneIICoreTests/ShpTests.swift::rowRleTransparent` exercises it.

## Where it lives in the reference

OpenDUNE `src/gui/gui.c::GUI_DrawSprite` at lines 1247–1259:

```c
while (count > 0) {
    uint8 v = *sprite++;
    if (v == 0) {
        v = *sprite++;        /* run length of transparent pixels */
        buf += v;
        count -= v;
    } else {
        *buf = v;
        buf += buf_incr;
        count--;
    }
}
```
