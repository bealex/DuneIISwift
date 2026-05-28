# Parity harness

How we verify the engine plays like Dune II 1.07. This is the operational doc; `../Plan.v1.md` §5 carries the rationale.

## Operational definition

**Behavioral parity = bit-identical wherever behavior is deterministic, and within OpenDUNE's own seed-to-seed spread wherever it is stochastic.** The pass criterion for a stochastic metric is not "close to one OpenDUNE run" but **"statistically indistinguishable from OpenDUNE run with a different seed."**

**Implementation fidelity vs. verification bar (do not conflate).** *Implementation requirement:* each state machine is an exact logical transcription of its EMC script — identical branches, conditions, thresholds, and order of primitive calls. *Verification bar for integrated play:* behavioral, because we deliberately do not reproduce the original's global tick scheduling or RNG draw-order. The implementation requirement is exactly testable per object (Tier 2a); the behavioral bar covers the integrated, multi-object result.

## The verification pyramid

- **Base — internal determinism (no oracle).** Same scenario + seed + command stream, run twice ⇒ byte-identical state. Catches accidental nondeterminism (Set/Dictionary iteration order, uninitialized reads, wall-clock leaks). Precondition for everything above.
- **Tier 1 — exact mechanics (golden tests on pure functions).** Both RNG generators (seed 0 → first 10k draws match); pathfinding routes for a corpus of (map, src, dst, movementType); damage / build-cost / speed / rotation / tile-enter-score formulas; `Tools_AdjustToGameSpeed`; map-from-seed (tile-for-tile); the stat tables.
- **Tier 2 — exact integration (RNG-controlled micro-scenarios).** Tiny scenarios run in both engines with full state-diff, kept exactly comparable by (a) choosing scenarios that consume **zero** RNG draws (verified by a draw counter), or (b) **semantically pinning** the few draws they hit (OpenDUNE tags each draw with the owning unit/structure, so both engines get the same value for the same decision regardless of stream position).
- **Tier 2a — per-object decision-trace equivalence (the direct test of "matches EMC exactly").** For an object in a given world state, single-step OpenDUNE's EMC interpreter and record the sequence of native-function calls (`FindBestTarget`, `CalculateRoute`, `Fire`, …) with arguments and resulting `ScriptEngine` variable changes; run our state machine on the equivalent state and assert it requests the **same primitives in the same order with the same arguments**. Localizes a transcription error to the exact branch that diverged.
- **Tier 3 — behavioral envelope (full scenarios).** (i) **Semantic event-trace alignment** — both engines emit a high-level event log (`actionChanged`, `unitFired`, `unitDied`, `structureBuilt`, `harvesterDocked`, `creditsChanged`, …); align the streams (tolerant on tick) and report the first divergent event. (ii) **Metric checkpoints** — credits, per-house counts, spice, fog — compared as curves with tolerances set to OpenDUNE's own across-seed standard deviation. (iii) **Distributional parity** — for inherently-random decisions, compare the distribution of an outcome across N seeds in both engines.

The Tier-3 event log is the same structured trace log mandated in CLAUDE.md ("trace logs are the parity stream"): make each `Log` call machine-parseable (tracer label + tick + entity id + payload) and the alignment harness falls out of logging we already do.

## OpenDUNE oracle mechanics

OpenDUNE under `Repositories/OpenDUNE/` is the **sole oracle** (it already carries parity hooks: `parity.c`, `Parity_DumpTick`, `Parity_DumpLandscape`, RNG/script trace hooks). Extend those to dump three fixture kinds **offline**: Tier-1 golden values, Tier-2/2a/3 traces + state snapshots, and Tier-3 N-seed batches. Commit the fixtures; CI tests against the committed fixtures (regenerate when widening coverage). For Tier-2 exact fixtures, OpenDUNE runs in the same RNG-controlled regime (stub/pin). Rejected alternative: a faithful EMC VM in a test-only target — it resurrects exactly the VM work we chose to avoid.

## Deliberate divergences (never mistaken for bugs)

- RNG draw-order differs from OpenDUNE by design.
- The off-screen script throttle (OpenDUNE runs off-screen units at 3 vs 52 opcodes) has no analogue in our state machines; assert at the metric level that it does not move outcomes.
- Converted original saves continue behaviorally-faithfully, not bit-identically.
- Compatibility flags pinned: `g_dune2_enhanced = false`; fixed `gameSpeed`.

## Honest caveat

This is strictly weaker than byte-exact. The residual risk is a transcription error that only manifests in an RNG-divergent branch never hit by a Tier-2 scenario; Tier-3 trace alignment + distributions are the net for that, but a net is not a proof. The trade is deliberate: extensibility and escaping the treadmill, in exchange for "plays the same" being rigorous rather than perfect.
