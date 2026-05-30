# Adding a `GameState` stored property can fail unrelated tests on an incremental build

**Finding:** inserting a stored property into `GameState` (a value type passed across module boundaries) and then running an *incremental* `swift test` can make a logically-unrelated test fail with garbage data — the dependent test module reads the struct with its **old** field layout from a stale `.swiftmodule`. The first time this bit us, adding `GameState.campaignID` (read only by structure-production code) made `SearchSpiceTests` return `0` for every query — as if landscape generation produced no spice — even though nothing it touches changed.

**Why it matters:** the symptom looks like a real regression in a subsystem you never edited (here: spice/landscape), so you chase a phantom bug. A clean build is green, which is the tell.

**Evidence:** `Code/Frameworks/DuneIIWorld/State/GameState.swift` (the `campaignID` field add); `Code/Tests/SimulationTests/SearchSpiceTests.swift` failed `result == 0` for all rows incrementally, passed under `Scripts/check.sh --full`. The reads are across the `DuneIIWorld` → `DuneIISimulation`/test boundary, where SwiftPM's incremental tracking missed the layout change.

**How to apply:** after changing `GameState`'s stored properties (add/remove/reorder), run `Scripts/check.sh --full` (clean build) before trusting a red result — don't debug a downstream test failure from an incremental run. This is already mandated by workflow step 5; the point here is that a *layout* change can surface as a failure far from the edit, so a surprising unrelated red after touching `GameState` is the cue to clean-build first.
