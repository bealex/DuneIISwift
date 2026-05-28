# Insights

Distilled non-obvious findings from implementation — one file per fact, so a future session learns the lesson without re-deriving it. Filename: `<category>-<slug>.md`. Categories: `format`, `codec`, `world`, `sim`, `parity`, `render`, `input`, `build`, `swift`.

Capture an insight when something surprised you, cost real time to figure out, or is a non-obvious invariant a future reader would trip over. Skip what the code, tests, or git history already record.

## Template

```
# <Title>

**Finding:** one-line statement of the non-obvious fact.

**Why it matters:** the consequence — what breaks or is wasted if you don't know this.

**Evidence:** our code `path:line`; the test that exercises it; the OpenDUNE source `src/<file>.c:<lines>` if applicable.

**How to apply:** the concrete rule to follow next time.
```

## Index

- [codec-format80-overlap](codec-format80-overlap.md) — Format80 back-references must be copied byte-by-byte (never bulk-copy), or overlapping runs corrupt.
- [swift-shift-precedence](swift-shift-precedence.md) — Swift `<<`/`>>` bind tighter than `*`/`/` (opposite of C); parenthesize ported bit math.
- [swift-string-split](swift-string-split.md) — split file text with `components(separatedBy: .newlines)`, not `split(separator:)`.
- [build-swiftpm-unhandled-files](build-swiftpm-unhandled-files.md) — non-source files in a target path warn; `exclude:` them, and audit warnings on a full clean build.
- [swift-toplevel-mainactor-globals](swift-toplevel-mainactor-globals.md) — top-level `let` globals in an executable's main.swift are @MainActor-isolated; nonisolated helpers can't use them.
