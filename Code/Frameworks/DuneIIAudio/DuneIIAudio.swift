/// Audio (postponed): an `AudioSink` protocol that consumes `SoundEvent`s, plus a Foundation-only
/// `NullAudio` now and a Core Audio implementation later.
///
/// Depends only on `DuneIIContracts` (the `SoundEvent` vocabulary) — never on the simulation. The
/// protocol + null sink land once `SoundEvent` exists (Phase 2); the real sink is Phase 7.
/// See `Documentation/Plan.v1.md`.
public enum DuneIIAudio {}
