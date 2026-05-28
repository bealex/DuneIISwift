/// Pure `Data` -> `Data` decoders and codecs for the original on-disk formats, plus the EMC
/// disassembler dev tool.
///
/// Decoders live under `Formats/<Name>/`, expose a single top-level type, and never read disk.
/// Codecs (`Format80`, `Format40`) are pure functions under `Codec/`. Foundation-only.
/// Populated in Phase 1 — see `Documentation/Plan.v1.md`.
public enum DuneIIFormats {}
