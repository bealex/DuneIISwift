/// Shared vocabulary and the seam types between the simulation and the presentation leaves.
///
/// Defines `FrameInfo`/`SpriteLayer` (simulation → renderer, see `FrameInfo.swift` +
/// `Documentation/Architecture/FrameInfo.md`), `Command` (input → simulation), and the shared
/// identifiers/enums (`HouseID`, `UnitType`, `StructureType`). `SoundEvent` (simulation → audio) lands
/// with Phase 7. Foundation-only. See `Documentation/Plan.v1.md` and `Architecture/Overview.md`.
public enum DuneIIContracts {}
