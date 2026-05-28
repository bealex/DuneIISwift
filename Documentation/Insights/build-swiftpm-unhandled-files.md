# Non-source files in a SwiftPM target path emit warnings

**Finding:** A per-module `CLAUDE.md` (or any non-source file) inside a target's source directory makes SwiftPM emit `warning: '<target>': found 1 file(s) which are unhandled` — one per such file. These count against the zero-warnings bar. In Phase 0 they scrolled past a `tail`-ed build and went unnoticed (the warnings appear early, during target scanning).

**Why it matters:** The project requires zero warnings on a clean build, and per-module `CLAUDE.md` is a standing convention — so every framework target needs the file excluded.

**Evidence:** `exclude: [ "CLAUDE.md" ]` on each framework target in `Code/Package.swift`.

**How to apply:** When adding a target with a `CLAUDE.md` (or README, fixtures, etc.) in its path, add `exclude:` for it in `Package.swift`. Audit warnings with the **full** output of a clean build (`swift package clean && swift build`), never a tailed/grepped subset, before claiming zero warnings.
