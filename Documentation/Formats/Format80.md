# Format80 (LCW compression)

Westwood's byte-oriented LZ77-style compression ("format80", a.k.a. LCW), used throughout Dune II's data: SHP/ICN sprite frames, CPS images, WSA animation frames, and more. We only **decode** it — the original tools compressed the data and the engine never recompresses, so there is no encoder (matching OpenDUNE, which ships only a decoder).

Reference: OpenDUNE `src/codec/format80.c:16` (`Format80_Decode`). Port: `Code/Frameworks/DuneIIFormats/Codec/Format80.swift`. Tests: `Code/Tests/FormatsTests/Format80Tests.swift`.

## Model

The decoder reads a stream of **command bytes** from the source and writes bytes to a destination buffer whose final length is known ahead of time (the containing format stores the uncompressed size in its header — so the size is an input to `decode`, mirroring the C signature `Format80_Decode(dest, source, destLength)`). Decoding stops at the `0x80` end marker or when the destination buffer is full, whichever comes first. `start` is the first output byte.

Two reference kinds appear: **relative** (copy from `dest - offset`, i.e. relative to the current write position) and **absolute** (copy from `start + offset`). All copies are **byte-by-byte**, so an overlapping back-reference replicates — that is how runs are expressed, and it is why the port must not use a bulk/`memcpy`-style copy.

## Commands

Let `cmd` be the command byte and `b0`, `b1`, `b2`, `b3` the bytes that follow it (paired values are little-endian). `remaining = destLength - written`; every `size` is clamped to `remaining`, and the offset/value bytes are always consumed even when the size clamps to fewer bytes.

| cmd | name | size | offset / value | action |
|---|---|---|---|---|
| `0x80` | End | — | — | Stop decoding. |
| `0x00`–`0x7F` (bit7 = 0) | Short copy, relative | `(cmd >> 4) + 3` (3–10) | offset = `((cmd & 0x0F) << 8) + b0` (1 byte) | copy `size` bytes from `dest - offset`, byte-by-byte |
| `0x81`–`0xBF` (bit7 = 1, bit6 = 0) | Literal run | `cmd & 0x3F` (1–63) | — | copy `size` bytes verbatim from the source |
| `0xC0`–`0xFD` (bit7 = 1, bit6 = 1) | Short copy, absolute | `(cmd & 0x3F) + 3` (3–64) | offset = `b0 + (b1 << 8)` (2 bytes) | copy `size` bytes from `start + offset`, byte-by-byte |
| `0xFE` | Long fill (RLE) | `b0 + (b1 << 8)` | value = `b2` | write `value` `size` times |
| `0xFF` | Long copy, absolute | `b0 + (b1 << 8)` | offset = `b2 + (b3 << 8)` | copy `size` bytes from `start + offset`, byte-by-byte |

## Worked example

Source `83 41 42 43 00 03`, destination length 6:
- `83`: literal run, size = `0x83 & 0x3F` = 3 → copy `41 42 43` ("ABC"). Written: `ABC`.
- `00 03`: short relative copy, size = `(0x00 >> 4) + 3` = 3, offset = `((0x00 & 0x0F) << 8) + 0x03` = 3 → copy 3 bytes from `dest - 3` = "ABC". Written: `ABCABC` (buffer now full, decoding stops).

Result: `41 42 43 41 42 43` ("ABCABC").

## Malformed input

The C reference assumes well-formed input and would read out of bounds on a truncated stream or a wild back-reference. The Swift port throws instead: `DecodeError.truncatedSource` when the source runs out mid-command, and `DecodeError.invalidBackReference` when a back-reference would address bytes outside `[0, destLength)`. Well-formed streams never hit these — behavior on valid input is identical to the C.
