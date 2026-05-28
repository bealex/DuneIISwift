/// Input: an `InputSource` protocol that produces `Command`s, plus a Foundation-only
/// `ScriptedInput` (for headless test scenarios) and (later) a `CatalystInput`.
///
/// Depends only on `DuneIIContracts` (the `Command` vocabulary) — never on the simulation. The
/// protocol + scripted source land once `Command` exists (Phase 2/5). See `Documentation/Plan.v1.md`.
public enum DuneIIInput {}
