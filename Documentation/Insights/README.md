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
- [render-contextual-palette](render-contextual-palette.md) — many CPS/WSA/SHP assets embed no palette; the correct one is loaded separately at runtime (mercenary mentat → BENE.PAL, intro/finale WSAs → INTRO.PAL, else IBM.PAL).
- [world-fog-veil-overlay-off-by-one](world-fog-veil-overlay-off-by-one.md) — our stored fog-veil `overlayTileID` is one higher than the oracle's (124 vs 123); gameplay-neutral (the unveil check result is unchanged), so map-tile goldens compare `groundTileID`, not overlay.
- [render-sandworm-blur-displacement](render-sandworm-blur-displacement.md) — `DRAWSPRITE_FLAG_BLUR` draws no worm pixels; it displaces the terrain under the worm's silhouette horizontally (a shimmer). It's a CoreGraphics effect in the leaf, not a sprite, and is subtle in a still — verify by diffing pixels.
- [render-tile-overlay-transparency](render-tile-overlay-transparency.md) — a tile overlay (wall/fog) composites over the ground with index-0 transparency (`GFX_DrawTile`), not an opaque blit; walls + fog share one `overlayTileID` slot, so faithful fog edges need a separate render-seam field.
- [render-snapshot-backing-scale](render-snapshot-backing-scale.md) — `SKView.texture(from:)` rasterizes at the host backing scale (2× Retina), so the CGImage is larger than the scene's logical size; scale a logical-point crop rect to pixels before `cropping(to:)` or it grabs the wrong region at half size.
- [render-structure-layout](render-structure-layout.md) — a building is a W×H grid of ICON.ICN tiles; its ICON.MAP group lists consecutive W·H-tile states (row-major), dimensions from structureInfo.layout. Built look = state index 2.
- [build-exec-eperm](build-exec-eperm.md) — sandboxed agent: direct clang/binary exec + out-of-repo writes are EPERM; build via the `.shim/gcc`→xcrun shim and a repo-local `TMPDIR` + `xcrun swift … --disable-sandbox`.
- [build-gamestate-layout-stale-module](build-gamestate-layout-stale-module.md) — adding/reordering a `GameState` stored property can fail an *unrelated* test with garbage data on an incremental build (stale `.swiftmodule` layout); clean-build before trusting the red.
- [sim-viewport-script-throttle](sim-viewport-script-throttle.md) — off-viewport units script at 3 (not 52) opcodes/tick; pin `viewportPosition` for parity.
- [sim-emc-unported-native-halt](sim-emc-unported-native-halt.md) — unported EMC natives must clean-halt (null the PC), not suspend, or timing skews silently.
- [sim-rng-stream-unpinned-wobble](sim-rng-stream-unpinned-wobble.md) — a fully-seeded golden divergence is a real draw-count bug, not "spread": trace-align both engines' draws (`--parity-random-trace`), find the first divergent index, fix the missing/extra draw (here: `GameLoop_Team`'s unconditional cursor re-arm). A `ctx=NULL` draw = a phase-level draw the other engine skipped.
- [world-slab-wall-bloom-are-map-tiles](world-slab-wall-bloom-are-map-tiles.md) — concrete/walls are painted tiles + freed structures (not pool objects); a tile's displayed `groundTileID` is separate from its `mapBaseTileID` revert base (don't corrupt the base when setting a bloom/overlay look).
- [parity-structure-placement-golden](parity-structure-placement-golden.md) — goldening a GUI/placement action: the oracle harness has no strings (player-house `GUI_DisplayText` crashes — keep the player powered, replicate only headless state-setup), `Unit_Find` skips in-transport units in the dump, and our `Unit_CreateWrapper` returns the carryall not the cargo (latent `originEncoded` bug).
- [world-map-occupancy-index-invariant](world-map-occupancy-index-invariant.md) — a tile's `hasUnit`/`hasStructure` flag implies a valid 1-based `index`; by-tile pool queries do `index - 1` unguarded, so stamping occupancy without the index crashes (slot −1).
- [sim-scenario-data-needs-sim-hook](sim-scenario-data-needs-sim-hook.md) — scenario sections whose effect needs a sim primitive (`[REINFORCEMENTS]`, `[MAP] Field`) can only be *parsed* in the World loader; realize them at a sim tick or a post-load Simulation hook, never from the loader.
- [world-structure-corner-position](world-structure-corner-position.md) — a structure stores its tile *corner* (`position &= 0xFF00`), not the centred sub-tile units use; the 128px offset is invisible to packed lookups but shifts every unit-vs-structure distance/aim calc.
- [parity-oracle-harness-untick-visual-subsystems](parity-oracle-harness-untick-visual-subsystems.md) — the oracle scenario harness ticks only the four GameLoop phases, not Explosion/Animation; gate any RNG-drawing visual subsystem's per-tick advance off the golden path (the RNG-free *start* is safe).
- [sim-movement-speed-entered-tile](sim-movement-speed-entered-tile.md) — a unit's per-step move speed comes from the tile it's *entering* (next tile in its facing), not the tile under it; recomputed each step, so terrain applies from the first step.
- [swift-expect-no-mutating-call](swift-expect-no-mutating-call.md) — a `mutating` method can't be called inside `#expect`/`#require` (the macro captures the value immutably); hoist the call into a `let` first.
- [sim-unported-native-marker-test](sim-unported-native-marker-test.md) — the UnitScriptRunner "unported native" tests hardcode an opcode; porting it breaks/crashes them — retarget the marker, and use `swift test --no-parallel` to find an opaque `Index out of range`.
- [render-incremental-appearance-key](render-incremental-appearance-key.md) — the renderer repaints only cells whose `CellAppearance` changed; any time-varying tile visual (fog edges, animations) must be in that key or it never updates live — and a single-frame render-golden won't catch the gap.
- [render-fog-two-passes](render-fog-two-passes.md) — fog hides things in two independent passes (terrain black-fill + a per-entity `isUnveiled` skip); the black terrain doesn't cover units, so each over-terrain drawable must fog-mask itself via `FrameComposer.isHiddenByFog`.
- [build-getbuildable-upgradelevel-gate](build-getbuildable-upgradelevel-gate.md) — `Structure_GetBuildable` gates on the factory's `upgradeLevel` (set in `Structure_Create`: Harkonnen light factory → 1); a synthetically-allocated factory at level 0 lists nothing — set `upgradeLevel` (or build via `structureCreate`) before suspecting the filter.
- [render-structure-healthbar-base-hp](render-structure-healthbar-base-hp.md) — a structure's health-bar denominator is its BASE HP (`StructureInfo[type].o.hitpoints`), not the power-degraded `Structure.hitpointsMax`; current HP can legitimately exceed the degraded cap (e.g. outpost 400/250), so dividing by it shows an over-full/wrong-length bar.
- [render-overlay-node-latch-jitter](render-overlay-node-latch-jitter.md) — a cell drawn alternately by the static background and a per-cell overlay node jitters a pixel at zoom (the two sampling paths disagree); latch a once-dynamic cell to the overlay path instead of toggling it back.
- [sim-fog-reveal-updatemap](sim-fog-reveal-updatemap.md) — continuous fog reveal is `Unit_UpdateMap(1)` → `Tile_RemoveFogInRadius(pos,1)` (radius 1, allied+non-sandworm), separate from the bigger `Script_Unit_RemoveFog` native; omitting it makes fog lag until the unit stops. Golden-safe (the oracle reveals too; no RNG).
- [sim-script-vm-engine-copy](sim-script-vm-engine-copy.md) — the script VM runs on a value-type COPY of the engine; natives that mutate the live script (`SetAction`, var-4 links) were clobbered on write-back — reconcile copy↔state around each dispatch. Fixed the harvester dock/refine/deploy stall.
- [sim-unit-corpse-overlay-animation](sim-unit-corpse-overlay-animation.md) — a dead foot unit's corpse is an OVERLAY animation from the `unitScript1/2` tables (distinct from structure animations); ported it (table-kind selector + `setOverlayTile`) so corpses linger ~1200 ticks then clear.
- [parity-savegame-record-sizes](parity-savegame-record-sizes.md) — an OpenDUNE save Object is 71 B (embeds a 55-byte ScriptEngine), so Unit=128/Structure=88; derive on-disk record sizes by summing the SLD_* disk types, not from a summary, and cross-check vs real chunk lengths.
- [parity-golden-regen-cwd](parity-golden-regen-cwd.md) — regenerate the function goldens from the repo root (ICON.MAP-backed categories truncate silently otherwise); always `git diff --stat` the Fixtures dir after and revert files you didn't mean to change.
- [build-test-filter-suite-name](build-test-filter-suite-name.md) — `swift test --filter`/`check.sh --filter` matches the test **type name**, not the `@Suite("…")` display string; a display-name pattern runs 0 tests and falsely reads green.
- [sim-unit-removefog-allied-only](sim-unit-removefog-allied-only.md) — Unit_RemoveFog reveals the player's fog only for player-allied units; missing the check made every enemy self-reveal (player sees all enemies + the AI makes instant contact). Caught by the `fog` golden (`veil` per-tile dump).
- [parity-oracle-headless-player-palace-missile](parity-oracle-headless-player-palace-missile.md) — the headless oracle SIGSEGVs on a ticked player-house palace, on flying any house missile, and in `Sound_Output_Feedback` (no strings); those player-palace/feedback behaviours can't be cross-engine goldens — verify in our engine + neutrality. (The loader must set `flags.human` for Brain=Human or the player palace auto-fires.)
- [sim-unit-death-audiovisual-three-sources](sim-unit-death-audiovisual-three-sources.md) — a unit's death effect comes from 3 independent sources (DIE-script `ExplosionSingle` boom / silent foot corpse overlay / the unimplemented `Sound_Output_Feedback` spoken cue) + the worm-swallow case; "destruction is sometimes silent" is expected, and adding a default explosion in `die()` double-explodes — don't.
