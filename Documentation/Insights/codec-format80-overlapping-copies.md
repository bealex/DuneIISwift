# Format80 absolute copies may overlap their own output

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Codec/Format80.swift`
- **Category**: codec
- **Applies to**: every caller of `Codec.Format80.decode` — CPS, WSA, SHP, ICN SSET.

## The fact

Both the short absolute copy (cmd with bits 7 and 6 set, not 0xFE/0xFF) and the long absolute copy (0xFF) can specify `offset + size > dp`. That is *not* a corruption signal — it's how Westwood's encoder emits run-length fills: "copy N bytes starting at offset; keep copying as I write". The copy reads bytes that were just written earlier in the same opcode.

## Why it matters

The first implementation of `Codec.Format80` guarded `offset + size <= dp` and threw `.truncated` on the check. Real CPS files failed to decode because this pattern fires constantly.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Codec/Format80.swift` — the 0xFF and `(cmd & 0x40) != 0` branches.
- `Code/Core/Tests/DuneIICoreTests/Format80Tests.swift::shortAbsoluteCopy` covers the overlap case.

## Where it lives in the reference

OpenDUNE `src/codec/format80.c` — no bounds check in either absolute-copy branch, just a naive byte loop that reads from `start[offset++]`.
