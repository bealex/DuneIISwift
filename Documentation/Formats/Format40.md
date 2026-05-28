# Format40 (XOR-delta compression)

Westwood's frame-delta codec, used for WSA animation deltas. Reference: OpenDUNE `src/codec/format40.c:14` (`Format40_Decode`). Port: `Code/Frameworks/DuneIIFormats/Codec/Format40.swift`. Tests: `Code/Tests/FormatsTests/Format40Tests.swift`.

The stream XORs runs onto an existing destination buffer (the previous frame), mutating it in place into the next frame, until the `0x80 0x00 0x00` terminator. "Skip" commands advance the write position without touching those bytes, so they carry over unchanged from the previous frame — which is why WSA must keep a running frame buffer.

## Commands

| First byte(s) | Action |
|---|---|
| `0x00`, then `count`, `value` | XOR `value` onto the next `count` bytes |
| `0x01`–`0x7F` (= `count`) | XOR the next `count` source bytes onto the destination |
| `0x81`–`0xFF` | skip `cmd & 0x7F` destination bytes |
| `0x80`, then 16-bit `n` (LE) | `n == 0`: end. `n < 0x8000`: skip `n`. `0x8000 ≤ n < 0xC000`: XOR-string `n & 0x3FFF`. `n ≥ 0xC000`: XOR-fill `n & 0x3FFF` with the next value byte |

We decode only. Malformed input throws `truncatedSource` / `destinationOverflow` rather than reading/writing out of bounds.
