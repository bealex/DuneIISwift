# DuneIISimulation

Game logic and the tick loop — the heart of the engine. Depends on `DuneIIWorld` + `DuneIIContracts`. Depends on no presentation leaf.

Contains the bit-exact native primitives (movement, rotation, pathfinding, fire/damage, harvest, economy), the per-type state machines (exact transcriptions of the disassembled EMC scripts — never invented), the four-phase `tick()` (Team → Unit → Structure → House), and the two-clock + speed/pause model. Applies `Command`s; emits `FrameInfo` + `SoundEvent`s. Headless and deterministic.

**Primitives are replaceable, never static.** Each native-primitive group is a `protocol` (e.g. `UnitPrimitives`) with an OpenDUNE-faithful default impl (`DefaultUnitPrimitives`), and `Simulation` holds an injected `any …Primitives` instance. Do **not** expose primitives as `static` functions — they must be swappable (reference vs. optimized, instrumented/decision-tracing, or test double). Leaf value-type math (`Tile32` geometry, `Tools`, `Orientation`, stat-table lookups in `DuneIIWorld`) stays static — that is pure data, not replaceable behaviour.

Every primitive cites its OpenDUNE `src/<file>.c:<lines>`. Every state machine is verified by per-object decision-trace equivalence (Tier 2a) before integration. Populated in Phase 3. See `Documentation/Architecture/ParityHarness.md`.
