# The TDD loop for a new feature

- **Discovered**: 2026-04-19 · this repo's conventions
- **Category**: workflow
- **Applies to**: every feature from P1 onwards.

## The fact

For every new feature we land:

1. **Write the format or algorithm doc first.** Use our own words; reference OpenDUNE or dunepak where we draw from them.
2. **Write a failing test next.** Synthetic input is preferred; add a real-data smoke test when a PAK entry exists that can exercise the path, short-circuiting when the install isn't present.
3. **Implement the feature.** Make the failing test pass with the minimum code needed. No speculative abstractions.
4. **Run the full suite.** `swift test` from `Code/Core/`. It must be green before the feature is "done."
5. **Log it.** Append a bullet to `Documentation/History/YYYY-MM.md`.
6. **If you learned something non-obvious, write an insight.** File under `Documentation/Insights/<category>-<slug>.md` and link from the Insights index.

The full phrasing lives in `CLAUDE.md` — this file exists to make it a citable insight when the loop gets short-circuited in a PR review.

## Why it matters

Every decoder in P1 had at least one "huh, I didn't expect that" moment that only surfaced when a failing test forced us to look at the bytes. Skipping the failing-test step means those surprises either ship as silent bugs or get re-discovered in P3 when the simulation actor starts consuming the output.

## Where it lives in our code

- `CLAUDE.md` — workflow section.
- `Documentation/Architecture/Testing.md` — what "tested" means per layer (format round-trip, golden simulation, save parity, etc.).
