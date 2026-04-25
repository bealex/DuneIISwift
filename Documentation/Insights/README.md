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
- [scripting-unit-entry-point-by-type-not-action](scripting-unit-entry-point-by-type-not-action.md) — `UNIT.EMC` entry points are indexed by unit TYPE (27 entries); the dispatch branches on `variables[0] = action`. Loading by action lands the PC inside another type's prologue — silent but visibly broken motion.
- [scripting-unit-getinfo-0b-is-currentdestination](scripting-unit-getinfo-0b-is-currentdestination.md) — `Script_Unit_GetInfo` subcase `0x0B` checks the per-step pixel `currentDestination`, not the ultimate `targetMove`. Misreading it makes MOVE handlers loop forever on the "already moving" wait.

### Simulation

- [simulation-house-free-leaves-used](simulation-house-free-leaves-used.md) — `House_Free` removes from the find-array but never clears `flags.used`; re-allocating the same slot afterwards fails.
- [simulation-findbesttarget-stamps-origin](simulation-findbesttarget-stamps-origin.md) — `Unit_FindBestTargetUnit` mutates the attacker's `originEncoded` on first call; priority also uses the *target's* fireDistance off-map (not the attacker's).
- [simulation-unitpool-bullets-share-slots](simulation-unitpool-bullets-share-slots.md) — bullets / missiles live in the same `UnitPool` as units; per-type `indexStart..indexEnd` ranges prevent collisions and cap concurrent bullets at 4.
- [simulation-getbuildable-signed-int-campaign-gate](simulation-getbuildable-signed-int-campaign-gate.md) — `Structure_GetBuildable`'s `availableCampaign - 1` promotes to signed int; ROCKET_TURRET's `availableCampaign = 0` passes the gate, and the upgrade-level requirement is what actually keeps it locked.
- [simulation-action-id-drives-script-reload](simulation-action-id-drives-script-reload.md) — writing `slot.actionID` is enough to re-enter the unit script; the scheduler's per-tick `loadedUnitAction` delta-check reloads the engine without explicit `Script_Reset` / `Script_Load` calls.
- [simulation-route-orientation-locked-to-step](simulation-route-orientation-locked-to-step.md) — while following a pathfinder route, `tickMovement` must pin `orientationCurrent = route[0] * 32` (canonical octant midpoint); recomputing from continuous pos32 delta made the sprite flicker across octant boundaries when the unit was off-axis.
- [simulation-off-viewport-3-opcode-cap](simulation-off-viewport-3-opcode-cap.md) — OpenDUNE caps unit scripts at 3 opcodes/tick for off-viewport units with `scriptNoSlowdown=false` (`src/unit.c:292..294`); a 17× script-throughput difference that only showed up via opcode-level VM tracing.
- [simulation-tick-sprite-runs-after-movement](simulation-tick-sprite-runs-after-movement.md) — OpenDUNE's `tickUnknown5` sprite-animation pass runs AFTER `Unit_MovementTick` in the per-unit loop; a reversed order animates one extra frame on every foot-unit arrival tick.
- [simulation-per-tick-rng-order-matters](simulation-per-tick-rng-order-matters.md) — identical RNG byte sequences can still diverge per-caller when two engines interleave draws differently; OpenDUNE runs per-unit {movement, rotation, script} while Swift batches those passes, so byte assignments drift silently until a `& 1` lands wrong hundreds of ticks later.
- [simulation-defer-free-on-death](simulation-defer-free-on-death.md) — `Unit_Damage` at hp=0 transitions to `ACTION_DIE` and leaves the slot alive; the DIE script dispatch (slot 0x0F `Script_Unit_Die`) frees it a few ticks later. Immediate-free on damage diverges the pool at every kill tick even though the visual corpse looks identical.
- [simulation-untarget-me-sweep](simulation-untarget-me-sweep.md) — `Unit_Remove` calls `Unit_UntargetMe` before `Unit_Free` to wipe stale `targetMove` / `targetAttack` encoded-index references across the pool. Skipping the sweep leaves attackers chasing ghosts and diverges parity dumps on every kill tick.
- [simulation-unit-free-mid-loop-skips-next-unit](simulation-unit-free-mid-loop-skips-next-unit.md) — `Unit_Free`'s memmove on `g_unitFindArray` shifts the tail left by 1 mid-iteration; the next `Unit_Find` call's `index++` advances past the shifted-in unit and silently skips its whole tick body (movement, fireDelay, script). Anything that needs OpenDUNE parity must keep all per-unit logic INSIDE the iteration, not in adjacent batched passes.
- [simulation-search-spice-no-caller-exclusion](simulation-search-spice-no-caller-exclusion.md) — `Map_SearchSpice` has no explicit caller-exclusion parameter; it skips a stationary harvester's own tile only because `Unit_UpdateMap` registers the harvester on the tile layer. Ports that add an explicit `excludingUnit` filter let the caller pick its own tile — invisible until that tile's landscape transitions during the same tick the script queries.
- [simulation-winger-offmap-removal](simulation-winger-offmap-removal.md) — `Unit_Move`'s off-map handler removes wingers through **two** gates, not one: `!mustStayInMap` OR (`mustStayInMap && byScenario && linkedID==0xFF && script.variables[4]==0`). Missing gate 2 lets save-initial CARRYALLs / ORNITHOPTERs fly forever. `Tile_IsValid` is a high-bit `0xC000` mask, not a tile-index bounds check.

### Render

- [render-mainactor-nested-enum-default-values](render-mainactor-nested-enum-default-values.md) — nested-enum `static let` defaults can't reference `@MainActor` statics on the enclosing class under Swift 6 strict concurrency; inline the literal.

### Audio

- [audio-voc-sample-rate-formula](audio-voc-sample-rate-formula.md) — the classic Creative rate formula `1_000_000 / (256 − divisor)`.

### Workflow

- [workflow-tdd-loop](workflow-tdd-loop.md) — write the test first, implement, update history + insight. See CLAUDE.md for the full loop.
- [workflow-opendune-parity-rng-reseed](workflow-opendune-parity-rng-reseed.md) — OpenDUNE's `SaveGame_LoadFile` never restores RNG state, and `OpenDune_Init` seeds the LCG from `time(NULL)`; parity harnesses must re-seed both RNGs *before and after* the save load to get reproducible replays.
- [workflow-parity-harness-audits-save-loader](workflow-parity-harness-audits-save-loader.md) — `ParityHarness` at `tickLimit=0` diffs post-save-load state against OpenDUNE's golden in ~50ms; catches the common class of bug where `Formats.Save.*` decodes a field but `WorldSnapshot(loading:baseline:)` forgets to copy it onto the live slot.
- [workflow-parity-skip-list-narrowing](workflow-parity-skip-list-narrowing.md) — when a parity drift lands on a tangential field (e.g. `u39.amount`), temporarily comment out its diff in `compareUnit` and rerun; the cascade of next-in-sequence halts on the same unit points straight at the real root cause.
