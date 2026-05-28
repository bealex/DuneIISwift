/// Game logic and the tick loop.
///
/// Will hold the bit-exact native primitives (movement, rotation, pathfinding, fire/damage,
/// harvest, economy), the per-type state machines (exact transcriptions of the disassembled EMC
/// scripts), the four-phase `tick()` (Team -> Unit -> Structure -> House), and the two-clock +
/// speed/pause model. Applies `Command`s and emits `FrameInfo` + `SoundEvent`s. Headless and
/// deterministic; depends on no presentation leaf. Populated in Phase 3 — see `Documentation/Plan.v1.md`.
public enum DuneIISimulation {}
