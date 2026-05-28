# DuneIIInput

Input. Depends only on `DuneIIContracts` (the `Command` vocabulary). Never depends on the simulation.

An `InputSource` protocol that produces `Command`s, with a Foundation-only `ScriptedInput` (replays a scripted event stream for headless test scenarios — the determinism hook for parity runs) and a `CatalystInput` (real). Input never mutates simulation state directly; it only produces `Command`s applied between ticks.

The protocol + `ScriptedInput` land once `Command` exists (Phase 2/5). See `Documentation/Plan.v1.md`.
