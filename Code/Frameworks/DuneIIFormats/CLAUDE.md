# DuneIIFormats

Pure `Data` → `Data` decoders/codecs for the original on-disk formats, plus the EMC disassembler dev tool. Foundation-only; depends on nothing.

Conventions: each decoder lives under `Formats/<Name>/`, exposes a single top-level type, and never reads disk (it takes `Data`). Codecs (`Format80`, `Format40`) are pure functions under `Codec/`. Ground each format in its OpenDUNE reference and document it under `Documentation/Formats/<Name>.md` first.

Phase 1 order: Format80, Format40, PAK, ICN/tiles, SHP, CPS, palette, FNT, WSA, VOC, INI, the SAVE IFF/FORM reader, and the EMC reader + `emc-disasm`. See `Documentation/Plan.v1.md`.
