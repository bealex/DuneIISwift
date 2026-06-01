# `swift test --filter` matches the type name, not the `@Suite` display string

**Finding:** `swift test --filter <pat>` (and `Scripts/check.sh --filter <pat>`) matches `<pat>` as a regex against the test **identifier** — `Module.TypeName/functionName` — **not** the human string in `@Suite("…")` / `@Test("…")`. So `--filter "Fog of war"` or `--filter "GameState pools"` (the display names) silently runs **0 tests**; you must use the struct/type name (`AIFogTests`, `GameStateTests`) or a `@Test` function name.

**Why it matters:** A 0-match filter reports `✅ 0 tests in 0 suites passed` — green, but it ran nothing. It reads as "my suite passed" when the suite never executed, so a broken test hides. Cost a retry twice in one session.

**Evidence:** `--filter "AIFogTests"` → 4 tests; `--filter "AI fog of war"` → 0. Same for `GameStateTests` (13) vs `"GameState pools …"` (0). Suite/test display strings live in the `@Suite`/`@Test` macro arg only.

**How to apply:** Filter by the **type name** of the test struct (or a `@Test` function name), never the `@Suite("…")` display string. If a `--filter` run shows `0 tests in 0 suites`, it's a non-match, not a pass — fix the pattern. `Scripts/check.sh --filter <TypeName>`.
