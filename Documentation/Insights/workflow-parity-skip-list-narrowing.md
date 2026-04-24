# Narrow cascading parity drifts by temporarily skipping fields in `compareUnit`

- **Discovered**: 2026-04-24 · `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift`
- **Category**: workflow
- **Applies to**: any SAVE*-parity session where `ParityHarness.runAgainst` reports a drift on a field that looks tangential to the actual root cause.

## The fact

`ParityHarness.compareUnit` halts on the first field mismatch it finds. That first mismatch is often a **downstream symptom** of a script-path divergence that starts several ticks earlier on a completely different unit. The halt hides the root cause.

The fastest way to locate the real root is to temporarily comment out the diff for the reported field and rerun. The next halt shows the next-in-sequence symptom; repeat until the halt lands on a field whose divergence is small, numeric, and clearly tied to a specific unit's state. That's the root.

## Why it matters

The tick-151 `u39.amount` drift on SAVE007 looked like a harvester RNG issue. Skipping `amount` surfaced tick-166 `u0.orientation0Target`. Skipping that surfaced tick-167 `u0.orientation0Current`, then tick-171 `u0.movingSpeed`, then tick-172 `u0.positionX`. All four were the same u0 carryall running a different script path than OpenDUNE; `u39.amount` was downstream RNG-stream drift from u0 consuming different `Tools_Random_256` bytes.

Without the skip-list, you might spend a day instrumenting `Script_Unit_Harvest` before realising the harvester itself is fine.

## Recipe

1. In `ParityHarness.compareUnit`, comment out the `try eq(...)` line for the currently reported field.
2. Re-run `saveSevenParityRealEmcFrontier` (or equivalent).
3. Read the new drift — note the tick, unit index, and field.
4. If the new drift is on the **same unit** as the prior one, comment it out too and repeat. That unit is the root cause candidate.
5. If the new drift is on a **different unit**, stop. The prior drift (now skipped) was the actual root, and the new drift is unrelated / a different session's work.
6. Revert every skip before committing — they're diagnostic only. `git checkout -- Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift` is faster than re-editing.

## Non-obvious corollary

The "run with skips" results encode a **map of cascading fields on one unit**. Recording the halt tick + field as you go (tick 151 → 166 → 167 → 171 → 172 → 196) tells you the order the unit's state diverges — which is useful for picking the right OpenDUNE function to port. A drift on `orientation0Target` before `movingSpeed` before `positionX` implies "script opcode that writes orientation happens before the one that writes speed," which narrows the suspect script function list.
