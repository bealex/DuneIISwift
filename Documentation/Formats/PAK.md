# PAK — Westwood PAK container

Status: Documented 2026-04-19

Dune II distributes its assets in a flat container called **PAK**. It is the simplest of Westwood's formats — no compression, no checksum, just an index followed by raw file bodies.

References:

- OpenDUNE `src/file.c` · `_File_Init_ProcessPak` (header walker).
- dunepak `src/main.rs` · `pak` / `unpak` (pack + unpack).
- Our decoder: `Formats.Pak.Archive` in `Code/Core/Sources/Formats/Pak/`.

## 1. Layout

```
┌────────────────────────────────────────────────────────────┐
│ Entry 1 offset   (u32 LE)       ← first byte of file       │
│ Entry 1 name     (ASCII + NUL, max 13 bytes incl. NUL)     │
│ Entry 2 offset   (u32 LE)                                  │
│ Entry 2 name     (ASCII + NUL)                             │
│ ...                                                        │
│ Entry N offset   (u32 LE)                                  │
│ Entry N name     (ASCII + NUL)                             │
│ Terminator       (u32 LE, value 0)                         │
│ Entry 1 body     (offset is absolute from start of file)   │
│ Entry 2 body                                               │
│ ...                                                        │
│ Entry N body                                               │
└────────────────────────────────────────────────────────────┘
```

Everything is little-endian. Filenames are DOS 8.3, uppercase, ASCII, zero padded with a single NUL terminator. They are **not** fixed-width — the NUL is the delimiter, so header entries are 4 + `strlen(name)` + 1 bytes each.

The terminator is a **zero offset**. The body of entry `k` occupies bytes `[offset[k], offset[k+1])`, and the last entry runs to EOF.

## 2. Worked example — `DUNE.PAK`

`Repositories/patched_107_unofficial/DUNE.PAK` opens with (spaces inserted for clarity, `\0` = NUL):

```
53 02 00 00   G R A Y R M A P . T B L \0     ← offset 0x00000253, name "GRAYRMAP.TBL"
53 15 00 00   A R R O W S . S H P \0         ← offset 0x00001553, name "ARROWS.SHP"
5F 18 00 00   B E N E . P A L \0
...
```

The first u32 `0x00000253` is the start of `GRAYRMAP.TBL` — which also tells us the header is 0x253 bytes long. The terminator `00 00 00 00` lives at offset `0x253 − 4 = 0x24F`. Everything before that is the index.

The size of `GRAYRMAP.TBL` is `0x00001553 − 0x00000253 = 0x1300` bytes.

## 3. Constraints (enforced by our decoder)

| Rule                          | Source                                    |
|-------------------------------|-------------------------------------------|
| Offsets are strictly ascending | Implicit; violating it means overlapping bodies. |
| Filenames ≤ 12 characters     | dunepak `main.rs` assertion; OpenDUNE uses 256-byte buffer but no real PAK exceeds 12. |
| Filenames are 7-bit ASCII     | dunepak `main.rs` `from_utf8` panic. |
| First offset > 4              | A valid file must have at least a terminator, so offsets start past the header. |
| Final body runs to EOF        | OpenDUNE `size = paksize - position` for the last entry. |

Malformed PAKs are rejected with a typed error — we do not attempt recovery. The original 1.07 PAKs are all well-formed.

## 4. Our Swift type

```swift
public enum Formats {
    public enum Pak {
        public struct Archive: Sendable {
            public struct Entry: Sendable {
                public let name: String        // uppercase, "DUNE.PAK"-style
                public let range: Range<Int>   // byte range into the backing Data
            }
            public let entries: [Entry]
            public func data(for entry: Entry) -> Data
            public func data(named name: String) -> Data?
        }
    }
}
```

Archives take ownership of a `Data` (ideally memory-mapped via `Data(contentsOf:options: .mappedIfSafe)`). They never re-read the file; all entry lookups are slice-from-memory. Filenames are indexed case-insensitively on read but preserved as-is for round-tripping.

## 5. Testing

`Core/Tests/DuneIICoreTests/PakTests.swift` asserts:

1. **Round trip** — encode a small archive, decode it, compare entries.
2. **Real input** — if `Repositories/patched_107_unofficial/DUNE.PAK` is present at test time, open it and assert:
   - ≥ 30 entries,
   - all names are uppercase ASCII ending in `.`-ext,
   - entry ranges are non-overlapping and monotonic,
   - concatenated entry sizes + header size == file size.
3. **Corruption** — a truncated header, a non-ASCII filename, and a non-monotonic offset each raise the expected typed error.

## 6. Related insights

- [format-pak-filename-ascii-8.3](../Insights/format-pak-filename-ascii-8.3.md) — the 13-byte name cap and ASCII-only rule come from real 1.07 data and dunepak's assertion.
