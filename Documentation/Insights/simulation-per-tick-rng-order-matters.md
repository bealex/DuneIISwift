# Per-tick RNG draw order depends on scheduler loop structure, not just which calls fire

- **Discovered**: 2026-04-24 · `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift` + SAVE007 tick-151 parity drift
- **Category**: simulation
- **Applies to**: any RNG-consuming script / movement / tick code; the parity harness's `Tools_Random_256` byte stream.

## The fact

`Tools_Random_256` is deterministic — same seed, same byte sequence. You can call it from any number of unrelated code paths and still get the same bytes in the same order. That makes RNG-stream parity feel robust: "just pass the same seed."

It isn't robust. The **byte a specific caller consumes** depends entirely on the **order in which callers fire within the tick**. Two engines can have identical byte streams and still diverge at a specific `Tools_Random_256() & 1` test if they interleave callers differently.

OpenDUNE's `GameLoop_Unit` (`src/unit.c:175..306`) runs a *per-unit* loop where each iteration does movement + wobble + rotation + script + delay-counter for one unit before moving to the next. Swift's scheduler ran those as *batched passes* across all units — all movement, then all rotation, then all scripts.

The batched form consumes the same total bytes per tick. But each caller's `idx` (position in the stream) shifts. At tick 1 of SAVE007, for example:

- OpenDUNE: `Unit_Find` visits u22 → its script calls DelayRandom → draws idx=1 (0xC0). Then u23..u35. Then u36 → movement pass draws wobble byte = idx=9 (0xCF).
- Swift: batched movement first → u36 wobble draws idx=0 (0x80). Then batched scripts → u22 DelayRandom draws idx=2 (0xE0).

Same 12 bytes per tick, identical total sequence, completely different assignment. Individual `& 1` or `& 0x1F` tests land on different byte values.

For most ticks this is invisible because the specific bit being tested has a 50/50 distribution anyway. For a few high-leverage ticks it flips a harvester bump, a fire-delay jitter, or an idle-action outcome, and the parity harness halts hundreds of ticks later on a field that looks unrelated to timing — e.g. `u39.amount=11 vs 12` at tick 151.

## Why it matters

Don't trust "byte-stream matches" as evidence of RNG parity. Confirm by diffing **caller attribution** — the `ctx=` column in the OpenDUNE `--parity-random-trace` dump and the matching `Scripting.RandomSource.currentTraceContext` tags on the Swift side. If the `idx → caller` mapping differs, the divergence will eventually surface even when the byte sequence matches 1:1.

## How to fix in Swift

Move `tickMovement` + `tickRotation` + `tickSpriteOffsets` (and anything else currently batched) into a per-unit dispatch loop mirroring OpenDUNE's `Unit_Find` iteration. Expect broad test adjustments — many gameplay tests pass under the batched form because they don't probe RNG timing.

A middle-ground workaround is cheaper and sometimes sufficient: re-order the batched passes so their RNG draws land in the same buckets OpenDUNE produces. This worked for tick-76 (the sprite/movement reorder insight) because only two passes interacted. It stops working once N passes interact non-linearly.

## Related

- [simulation-tick-sprite-runs-after-movement](simulation-tick-sprite-runs-after-movement.md) — a specific ordering constraint already captured. Fixing that closed tick-76 but didn't solve the structural gap.
- [workflow-parity-skip-list-narrowing](workflow-parity-skip-list-narrowing.md) — the diagnostic technique that surfaced the u0 cascade, which in turn surfaced this scheduler-order gap.
