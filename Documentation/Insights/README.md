# Insights

Distilled, non-obvious findings from implementing Dune II. An insight is a fact that is *not* derivable from reading our own code, is too narrow to deserve its own architecture doc, and is easy to re-discover the hard way if it's not written down.

## When to write an insight

Write one whenever a feature lands and you thought, at some point, "huh, I didn't expect that." Typical triggers:

- A spec is missing or wrong; the truth only comes from reading the reference C code or the bytes on disk.
- A test that should have passed on first try didn't — and the bug was in a load-bearing assumption you made about the format, not a typo.
- A decision that would surprise the next reader ("why doesn't this decoder validate X?") — the reason goes here.

One insight per discrete fact. If you find yourself writing two unrelated sections, split the file.

## What does *not* belong here

- Re-statement of the file format — the format doc owns that.
- General software-engineering advice.
- Status updates — the monthly history owns those.

## File layout

Filenames: `<category>-<kebab-slug>.md`

Categories used so far:
- `codec-*` — Format80/Format40 subtleties.
- `format-*` — per-format gotchas.
- `render-*` — anything about palette, transparency, or drawing.
- `audio-*` — VOC/XMI oddities.
- `scripting-*` — EMC VM and script-table quirks.
- `simulation-*` — pool / entity / tick quirks.
- `workflow-*` — toolchain or repo-structure notes.

Every file starts with the same frontmatter-style header:

```markdown
# <one-line title>

- **Discovered**: YYYY-MM-DD · `path/to/relevant/code`
- **Category**: codec / format / render / audio / workflow
- **Applies to**: short list of modules/files this bites

## The fact

Bullet-point, terse. One to three sentences max.

## Why it matters

What breaks if you don't know this.

## Where it lives in our code

`Code/Core/Sources/...` — file:line references.

## Where it lives in the reference

OpenDUNE `src/...` or dunepak `src/...` or the raw bytes of
`INSTALL/FOO.PAK`.
```

## Index

### Codec

- [codec-format80-overlapping-copies](codec-format80-overlapping-copies.md) — absolute copies may read their own output; don't guard against it.

### Formats

- [format-pak-filename-ascii-8.3](format-pak-filename-ascii-8.3.md) — DOS PAK filenames are uppercase 7-bit ASCII, ≤ 12 chars, NUL-terminated.
- [format-palette-vga-6bit-scaling](format-palette-vga-6bit-scaling.md) — scale 6-bit VGA to 8-bit with bit replication, not `<< 2`.
- [format-shp-offset-table-overlap](format-shp-offset-table-overlap.md) — the SHP offset table stores `count + 1` u32s; `offset[0] + 2` lands on the frame header, and the 2 bytes it skips overlap with the next entry.
- [format-shp-row-rle-transparency](format-shp-row-rle-transparency.md) — after format80, SHP pixel data is still run-length encoded with `0x00 N` = N transparent pixels.
- [format-wsa-continuation-files](format-wsa-continuation-files.md) — a WSA with `offsets[0] == 0` is a continuation; do not error.
- [format-icn-subpalette-indirection](format-icn-subpalette-indirection.md) — ICN tiles are 4-bit; each tile carries an index into a 16-byte sub-palette that maps to the global PAL.
- [format-cps-decoded-size-unused-when-compressed](format-cps-decoded-size-unused-when-compressed.md) — the `decodedSize` u32 in a CPS file is only consulted for uncompressed images; for Format80-compressed CPS, use 64000 directly.
- [format-iconmap-double-indirection](format-iconmap-double-indirection.md) — `ICON.MAP` header entries are indices into the same array; tile IDs live at `map[map[group] + k]`.
- [format-ini-case-insensitive-keys](format-ini-case-insensitive-keys.md) — lookup is case-insensitive, storage preserves case, and duplicate keys are last-wins.
- [format-emc-variable-instruction-width](format-emc-variable-instruction-width.md) — EMC opcodes are 1 or 2 u16 words; flag bits in the first word pick.
- [format-xmi-delay-and-duration](format-xmi-delay-and-duration.md) — XMI delays are plain accumulated bytes, and note-off is scheduled via the note-on's VLQ duration (not a separate event).
- [format-tile-packxy-uint16-bounds](format-tile-packxy-uint16-bounds.md) — `Tile_PackXY` has no bounds checks; the `0xF000` out-of-map bit catches three of four edge cases, with `x = 64` silently wrapping east.
- [format-save-odun-is-opendune-only](format-save-odun-is-opendune-only.md) — `ODUN` is an OpenDUNE-only chunk; original 1.07 saves emit only six chunks (`NAME` / `INFO` / `PLYR` / `UNIT` / `BLDG` / `MAP `), and `TEAM` is conditional.
- [format-save-info-duplicate-credits](format-save-info-duplicate-credits.md) — the `INFO` chunk writes `g_playerCreditsNoSilo` twice (payload offsets 228 and 266); the second write wins — not a distinct "reserve credits" field.
- [format-save-odun-repairs-narrowed-fields](format-save-odun-repairs-narrowed-fields.md) — `ODUN` exists to patch fields the `UNIT` record narrowed on disk (`fireDelay` u16→u8, `deviatedHouse` added), not to add new state.
- [format-save-map-is-sparse-not-fixed](format-save-map-is-sparse-not-fixed.md) — `MAP ` stores only tiles differing from the seed baseline or carrying dynamic state; reconstructing the full grid needs `Core.Map.Generator` output as the baseline.

### Scripting

- [scripting-emc-saved-location-plus-one](scripting-emc-saved-location-plus-one.md) — `PUSH_RETURN_OR_LOCATION 1` saves `pc + 1` because the EMC compiler always emits a `JUMP` immediately after the call setup.
- [scripting-host-fn-peek-not-pop](scripting-host-fn-peek-not-pop.md) — host functions must read args via `peek`, never pop; the EMC compiler emits a `STACK_REWIND` after every call to clean up.

### Simulation

- [simulation-house-free-leaves-used](simulation-house-free-leaves-used.md) — `House_Free` removes from the find-array but never clears `flags.used`; re-allocating the same slot afterwards fails.
- [simulation-findbesttarget-stamps-origin](simulation-findbesttarget-stamps-origin.md) — `Unit_FindBestTargetUnit` mutates the attacker's `originEncoded` on first call; priority also uses the *target's* fireDistance off-map (not the attacker's).
- [simulation-unitpool-bullets-share-slots](simulation-unitpool-bullets-share-slots.md) — bullets / missiles live in the same `UnitPool` as units; per-type `indexStart..indexEnd` ranges prevent collisions and cap concurrent bullets at 4.

### Audio

- [audio-voc-sample-rate-formula](audio-voc-sample-rate-formula.md) — the classic Creative rate formula `1_000_000 / (256 − divisor)`.

### Workflow

- [workflow-tdd-loop](workflow-tdd-loop.md) — write the test first, implement, update history + insight. See CLAUDE.md for the full loop.
