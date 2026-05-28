# DuneIIAudio

Audio — postponed. Depends only on `DuneIIContracts` (the `SoundEvent` vocabulary). Never depends on the simulation.

An `AudioSink` protocol that consumes `SoundEvent`s, with a Foundation-only `NullAudio` now and a Core Audio implementation later (Phase 7). The simulation emits `SoundEvent`s rather than calling audio inline; the seam is built early (Phase 2) so the real sink slots in without touching sim call sites.

See `Documentation/Plan.v1.md`.
