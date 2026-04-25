# Parity harness doubles as a save-loader audit

- **Discovered**: 2026-04-23 · `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift`, `Code/Core/Tests/DuneIICoreTests/ParityHarnessTests.swift`
- **Category**: workflow
- **Applies to**: any "save record → live slot" propagation path, especially `Simulation.WorldSnapshot`

## The fact

`Simulation.ParityHarness.runAgainst(snapshot:golden:tickLimit:...)` with `tickLimit = 0` diffs pool state at tick 0 — the **post-save-load, pre-first-tick** moment. OpenDUNE and Swift both see the same save bytes at this point, so any divergence is a loader bug, not a simulation bug.

Running this against `_SAVE001.DAT` on day one caught a class of bug that no unit test in `SimulationWorldSnapshotTests` would surface on its own: `Formats.Save.Units.Slot` had `speedPerTick / speedRemainder / movingSpeed / currentDestinationX / currentDestinationY` decoded correctly, but `WorldSnapshot(loading:baseline:)` never copied those fields onto the live `UnitSlot`. Every existing test that loaded a real save happened to care about *other* fields, so the gap stayed invisible until the parity diff landed on `unit[22].speedRemainder = 232` (golden) vs `= 0` (live).

## Why it matters

The natural instinct when adding a save-record field is to:

1. Decode it in `Formats/Save/*`.
2. Add a test that the decoder reads it.
3. Move on.

That misses step 4: "propagate it in `WorldSnapshot.init(loading:baseline:)`." Nothing statically enforces the two sides stay in sync — our `Slot` type is value, `WorldSnapshot` reads whatever fields the author remembered to copy. An incomplete copy is silent.

**The parity harness makes it loud.** Tick 0 runs in ~50ms. Drop a new field into the golden schema and it turns red the instant the loader drops the ball. Treat green tick 0 as the contract: every save-record field with a corresponding live-slot field gets propagated, or the test catches it.

Concretely, the loop for adding a new field now looks like:

1. Add to the save decoder (`Formats/Save/*.swift`) + decoder test.
2. Add the field to the slot (`Simulation/*Pool.swift`).
3. Propagate in `WorldSnapshot(loading:baseline:)` *and* `WorldSnapshot(scenario:resolver:)`.
4. Regenerate the golden if needed (OpenDUNE had the field), or widen the Swift-side compare in `ParityHarness.compareX` (we had it but weren't diffing it).
5. Run `ParityHarnessTests.saveOneParityTickZero` — green means the field round-tripped.

Step 5 used to be "run the whole scenario and eyeball the behaviour." It's now one 50ms assertion.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift` — `runAgainst(...)` + `compareUnit` / `compareStructure` / `compareHouse`. The skip-list comments show which fields are live-slot-backed but not yet diffed.
- `Code/Core/Tests/DuneIICoreTests/ParityHarnessTests.swift:saveOneParityTickZero` — pins the contract for tick 0.
- `Code/Core/Tests/DuneIICoreTests/Fixtures/ParityGoldens/save001_200ticks.jsonl` — the ground truth (gitignored; regenerate from OpenDUNE per `Documentation/Architecture/opendune-parity-patch/README.md`).

## Where it lives in the reference

- `Repositories/OpenDUNE/src/saveload/unit.c` — `s_saveUnit` table; every entry here *must* have a matching propagation in our `WorldSnapshot` if its field is also in `UnitSlot`.
- `Documentation/Architecture/opendune-parity-patch/tick_parity_dump.patch` — defines the golden schema (whatever fields `Parity_DumpUnits` in `src/parity.c` writes are the authoritative list).
