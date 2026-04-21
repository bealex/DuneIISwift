# PAK filenames are uppercase 7-bit ASCII, ≤ 12 chars, NUL-terminated

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Pak/PakArchive.swift`
- **Category**: format
- **Applies to**: `Formats.Pak.Archive`, `Formats.Pak.Encoder`, anything that resolves filenames across the engine.

## The fact

Filenames in a PAK header are DOS 8.3, stored as ASCII bytes terminated by a single NUL. No padding, no fixed width. `dunepak` asserts length ≤ 12 and rejects any byte ≥ 0x80. Every shipped 1.07 PAK respects both.

## Why it matters

Our PAK reader uses a hard 13-byte cap (12 name bytes + NUL) and rejects non-ASCII bytes. If a future OpenDUNE fork adds UTF-8 mod support we'd need to loosen this — but for real 1.07 data, anything that violates the cap is corruption.

## Where it lives in our code

- `Formats/Pak/PakArchive.swift::parseIndex` enforces the cap.
- `Tests/DuneIICoreTests/PakTests.swift::corruptNonAscii` + `::corruptTruncated` cover the two rejection paths.

## Where it lives in the reference

dunepak `src/main.rs::read_filename_with_nul` — `assert!(i <= 12, ...)`. OpenDUNE `src/file.c::_File_Init_ProcessPak` uses a 256-byte buffer but every real PAK stays within 12.
