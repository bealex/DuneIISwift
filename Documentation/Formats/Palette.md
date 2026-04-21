# PAL — VGA palette

Status: Documented 2026-04-19

Dune II stores palettes in raw VGA format — 256 × 3 bytes, each channel a **6-bit** value in the range 0…63. This reflects the IBM VGA DAC, which accepted 6-bit color writes (the top two bits of the byte were ignored).

References:

- OpenDUNE `src/opendune.c` · `File_ReadBlockFile("IBM.PAL", g_palette1, 256 * 3)`.
- OpenDUNE `INTERNALS.txt` — palette organisation (action colors, house remap bands, light table ramps).
- Our decoder: `Formats.Palette` in `Code/Core/Sources/DuneIICore/Formats/Palette/`.

## 1. Layout

```
offset  size  content
0       3     color 0: R, G, B       (each 0…63)
3       3     color 1
...
765     3     color 255
```

Total: 768 bytes, no header, no terminator. Any channel byte ≥ 64 indicates a corrupt file — we reject it.

## 2. 6-bit → 8-bit conversion

The typical `value << 2` scaling maps 63 → 252, losing the top three levels. We use **bit replication** so 63 maps to 255:

```
rgb8 = (rgb6 << 2) | (rgb6 >> 4)
```

This matches DOSBox and every modern Westwood-format viewer.

## 3. Palettes in the install

| File           | Used by                                    |
|----------------|--------------------------------------------|
| `IBM.PAL`      | Standard in-game palette (all map screens).|
| `BENE.PAL`     | Mentat briefing overlay.                   |
| `INTRO.PAL`    | Intro cutscene.                            |
| `WESTWOOD.PAL` | Westwood logo fade.                        |

## 4. Embedded palettes

Both CPS and SHP files can carry their own palette:

- CPS: up to 768 bytes immediately after the 8-byte header (see `CPS.md`).
- SHP: a fixed **16-entry house-remap** slice when frame flag bit 0 is set; this is not a full palette (see `SHP.md`).

`Formats.Palette.fromPartial(_:)` handles short CPS palettes by zero-padding the rest; SHP's 16-entry slice is handled by its own decoder.

## 5. Testing

`Core/Tests/DuneIICoreTests/PaletteTests.swift` asserts:

1. Round-trip a synthetic 768-byte buffer.
2. `rgba8` of `(63, 63, 63)` is `0xFFFFFFFF`; `(0, 0, 0)` is `0x000000FF`.
3. Any channel ≥ 64 raises `channelOutOfRange`.
4. If `IBM.PAL` is extractable from the real `DUNE.PAK`, it decodes to exactly 256 colors with all channels ≤ 63.

## 6. Related insights

- [format-palette-vga-6bit-scaling](../Insights/format-palette-vga-6bit-scaling.md) — why we use bit replication instead of `<< 2` when scaling to RGB8.
