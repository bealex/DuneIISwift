# The UnitScriptRunner "unported native" tests hardcode an opcode — porting it breaks (or crashes) them

**Finding:** `UnitScriptRunnerTests` has two tests that assert an *unported* native clean-halts: one calls `dispatch(0xNN, …) == nil`, the other runs a `[inlineOp(14, 0xNN)]` program and expects the run to halt with a nulled PC. They hardcode a specific opcode `0xNN` as "the unported one". When you later port `0xNN`, the first test fails (`== nil` no longer holds) and the second **crashes** — the now-ported native executes against the test's minimal synthetic `GameState` (e.g. `ExplosionMultiple` → `Map_MakeExplosion` over an unpopulated map) and hits an out-of-range index / fatal error, which in the parallel runner shows up as an opaque `ContiguousArrayBuffer … Index out of range` with no obvious owner.

**Why it matters:** it has bitten twice (0x04 → retargeted to 0x12 → retargeted to 0x14). The crash is confusing because the failing assertion and the fatal error look unrelated to the slice you just shipped, and parallel testing hides which test owns it (`swift test --no-parallel` reveals it — the test that "started" right before the fatal line is the culprit).

**How to apply:** when you port a unit native, grep `UnitScriptRunnerTests` for the hardcoded marker opcode; if it's the one you just ported, retarget both tests to a still-unported opcode (pick one unlikely to be ported soon). If the full suite dies with a bare `Index out of range`, re-run `swift test --no-parallel` and read the last `Test "…" started` before the fatal.

**Evidence:** `Code/Tests/SimulationTests/UnitScriptRunnerTests.swift` (the `dispatch routes …` + `run halts cleanly on an unported native` tests).
