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
- [swift-spm-macos-gui](swift-spm-macos-gui.md) — native macOS SwiftUI apps run as SPM executables (`swift run`); set `.regular` activation policy so the window shows.
- [render-palette-animation](render-palette-animation.md) — indices 223/239/255 are magenta placeholders meant to be palette-cycled; render with the time-cycled palette or animated tiles look wrong.
- [sprite-global-indices](sprite-global-indices.md) — unit sprite IDs are global indices into a concatenated array (per-file local = global − base offset); frame grouping + directional/animation labels live only in unitInfo, not the SHP.
- [render-contextual-palette](render-contextual-palette.md) — SHP sprites carry no palette; mentat faces (MENSHP*) use their MENTAT<house>.CPS palette, not IBM.PAL. Palette follows the screen the sprite is drawn over.
