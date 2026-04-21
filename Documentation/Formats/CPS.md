# CPS — Compressed full-screen image

Status: Documented 2026-04-19

CPS holds a single 320×200 paletted image. Dune II uses it for title cards (`MAPMACH.CPS`, `DUNEMAP.CPS`), the mentat backgrounds (`MENTATA.CPS` etc.), the FAME credits screen, region maps, and so on.

References:

- OpenDUNE `src/sprites.c` · `Sprites_LoadCPSFile` reads the file.
- OpenDUNE `src/sprites.c` · `Sprites_Decode` dispatches on compression tag.
- Our decoder: `Formats.Cps.Image` in `Code/Core/Sources/DuneIICore/Formats/Cps/`.

## 1. Layout

```
offset  size  content
0       2     fileSizeMinus2 (u16 LE) — ignored by us; we trust Data.count
2       2     compression tag (u16 LE):
                0x0000 = uncompressed
                0x0004 = Format80
4       4     decoded image size (u32 LE) — always 0x0000FA00 = 64000
8       2     palette size in bytes (u16 LE), 0 if no palette
10      P     optional partial palette (P = paletteSize, up to 768)
10+P    …     image payload (raw or Format80-encoded)
```

After decoding, pixels are 320×200 row-major 8-bit palette indices.

## 2. Palette handling

If `paletteSize` is 0, the file expects the caller to have loaded an external palette (`IBM.PAL` typically). Otherwise the embedded palette covers the first `paletteSize / 3` entries — we zero-pad the rest via `Formats.Palette.fromPartial(_:)`.

## 3. Compression: Format80

When the compression tag is `0x0004`, the image payload is fed straight into `Codec.Format80.decode(_:destinationCapacity:)` with a capacity of
64000. Both `0x0000` and `0x0004` are seen in the 1.07 data; OpenDUNE's `Sprites_Decode` rejects everything else.

## 4. Swift API

```swift
let data = archive.body(named: "MAPMACH.CPS")!
let image = try Formats.Cps.decode(data)
// image.pixels.count == 64_000
// image.palette may be nil if the file had no embedded palette
```

## 5. Testing

`Core/Tests/DuneIICoreTests/CpsTests.swift` covers:

1. Synthetic uncompressed image (320×200 of a single palette index).
2. Synthetic Format80-compressed image (one big fill).
3. Rejection of unsupported compression tags.
4. Real input: if `DUNE.PAK` is present, decode `MAPMACH.CPS` and assert its pixel buffer is exactly 64000 bytes.

## 6. Related insights

- [format-cps-decoded-size-unused-when-compressed](../Insights/format-cps-decoded-size-unused-when-compressed.md) — the u32 at `[4..7]` is ignored for Format80 CPS; use 64000 directly.
- [codec-format80-overlapping-copies](../Insights/codec-format80-overlapping-copies.md) — bites real CPS images; our Format80 must allow forward-overlap.
