# DuneIIContracts

The shared seam vocabulary between the simulation and the presentation leaves: `FrameInfo` (simulation → renderer), `Command` (input → simulation), `SoundEvent` (simulation → audio), plus shared IDs/enums. Foundation-only; depends on nothing.

Keep this layer tiny and dependency-free — it is what prevents circular dependencies between the leaves. The simulation produces `FrameInfo`/`SoundEvent` and consumes `Command`; renderer/input/audio sit on the other side. Populated in Phase 2.

See `Documentation/Plan.v1.md` §4 and `Documentation/Architecture/Overview.md`.
