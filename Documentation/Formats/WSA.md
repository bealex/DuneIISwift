# WSA — Pre-rendered animation

Status: Documented 2026-04-19

WSA stores short cinematic animations. Used for the intro, mentat lip-sync, mission win/lose screens, and the "lost building" / "lost vehicle" dialog stingers. Each frame is a delta applied onto a shared display buffer — i.e. frame N's pixels are frame N-1's pixels XORed with a per-frame "XOR stream".

References:

- OpenDUNE `src/wsa.c` · `WSA_LoadFile` (header + offset table) and `WSA_GotoNextFrame` (the decode pipeline).
- Our decoder: `Formats.Wsa.Animation` in `Code/Core/Sources/DuneIICore/Formats/Wsa/`.

## 1. Layout

Modern (v1.07) header — 10 bytes, all u16 LE:

```
offset  field
0       frames        (high bit sometimes set; mask 0x7FFF)
2       width
4       height
6       requiredBufferSize
8       hasPalette    (0 or 1)
```

Legacy (v1.0) omits the `hasPalette` field — the header is 8 bytes and no palette is ever present. We detect legacy via the same heuristic OpenDUNE uses: if `offsets[0] != lengthHeader + 8 + 4 * frames` and `offsets[1] != lengthHeader + 8 + 4 * frames`, fall back to 8-byte header.

After the header:

```
offsets[0..frames+1]   (frames + 2) × u32 LE
[palette]              768 bytes if hasPalette
frame payloads         back-to-back, addressed via the offsets
```

`offsets[i]` is the absolute file byte where frame `i`'s compressed payload begins. `offsets[frames]` is the end of the last frame. `offsets[frames+1]` is an "end of animation" sentinel — if zero, the file is a still image.

## 2. Per-frame pipeline

Each frame's payload is a Format80 stream that decodes to a Format40 XOR stream. The XOR stream is then applied (in place) to the running display buffer. Pseudo-Swift:

```swift
var display = Data(repeating: 0, count: width * height)
for i in 0..<frames {
    let payload = file[offsets[i]..<offsets[i+1]]
    let xorStream = Format80.decode(payload, cap: workingBuf)
    Format40.decode(source: xorStream, destination: &display)
    yield Array(display)
}
```

When `offsets[0] == 0`, the WSA is a **continuation** of another WSA — the display buffer should be pre-seeded from the previous file's last frame. (Seen in multi-part cutscenes; we accept the file and XOR from zero as OpenDUNE does.)

## 3. Swift API

```swift
let data = pak.body(named: "INTRO.WSA")!
let anim = try Formats.Wsa.decode(data)
// anim.frames.count == N, each frame is anim.width * anim.height palette indices
```

## 4. Testing

`Core/Tests/DuneIICoreTests/WsaTests.swift`:

1. Synthetic one-frame WSA with a constant-fill frame decodes to the expected buffer.
2. Synthetic continuation WSA (`offsets[0] == 0`) emits an initial zero frame without error.
3. Truncated headers are rejected.
4. If `DUNE.PAK` is present, decode `STATIC.WSA`, `LOSTVEHC.WSA`, `LOSTBILD.WSA` and assert every frame has `width * height` pixels.

## 5. Related insights

- [format-wsa-continuation-files](../Insights/format-wsa-continuation-files.md) — six shipped WSAs use `offsets[0] == 0`; they must not error.
