# Testing strategy

Run the full suite with `cd Code/Core && swift test` — it must be green before any feature is "done." Zero warnings after `swift package clean && swift build`. Framework: **Swift Testing** (`import Testing`). Synthetic input is preferred; real-data / oracle tests use the install (`Repositories/patched_107_unofficial/`) and short-circuit when it is absent.

## Per layer

- **Formats / codecs (`DuneIIFormats`).** Round-trip every writer; a test per format-variant branch; a test per throwing case; real-data decode against PAK entries when available.
- **World (`DuneIIWorld`).** Scenario `.INI` load; our save round-trip (bit-exact); the original-save converter; golden tests for both RNG sequences and map-from-seed.
- **Simulation (`DuneIISimulation`).** Internal determinism (same seed + input ⇒ identical run, run twice and diff); per-object decision-trace equivalence vs the EMC interpreter (Tier 2a); RNG-controlled micro-scenarios diffed exactly vs OpenDUNE (Tier 2); full-scenario behavioral envelope (Tier 3).
- **Renderer (`DuneIIRenderer`) + `rendertest`.** `rendertest` displays every sprite/animation for every house; sampled frames diff pixel-exact against reference PNGs; the renderer reproduces a recorded `FrameInfo`.
- **Input / Audio.** The mock implementations (`ScriptedInput`, `NullAudio`) drive headless scenarios; the `Command` and `SoundEvent` seams are exercised.

## Behavioral parity

The verification pyramid (internal determinism → exact mechanics → exact integration → behavioral envelope), the per-object decision-trace check, the OpenDUNE oracle/fixture mechanics, and the deliberate-divergence catalog are all in `ParityHarness.md`.

## Coverage bar

See CLAUDE.md → "What counts as tested." In short: every throwing case, every format-variant branch, every writer round-trip, every native primitive against an OpenDUNE golden, every state machine via decision-trace equivalence, and every public function on real or synthetic input.
