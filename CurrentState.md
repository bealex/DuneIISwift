# Current State

**Branch:** `main` (commit directly on `main`). **Plan of record:** `Documentation/Plan.v1.md`. **Architecture:** `Documentation/Architecture/Overview.md`. **Per-round loop:** `Scripts/check.sh` (build+test) → `Scripts/log-history.sh "<bullet>"` → update this file → commit (see `CLAUDE.md` → "Running things").

> **This file is the operational resume point — keep it SHORT.** The full dated changelog lives in `Documentation/History/` (append-only, one file per day; `History/README.md` indexes it). Golden/parity detail + how-to-regenerate is in `Architecture/ScenarioHarness.md`, `Testing.md`, `ParityHarness.md`. The living gameplay done/not-done table is `Architecture/FeatureParity.md`. Past self-review outcomes are folded into `CLAUDE.md` standing rules + `Documentation/Insights/`. Do not let "Recently completed" grow without bound — trim it to the last handful and let History hold the rest.

## Status

The engine is **feature-complete and cross-engine-verified against OpenDUNE 1.07.** All phases have working, tested first versions: the headless four-phase battle sim (Phases 0–3, bit-exact primitives + exact EMC transcriptions), the `FrameInfo`-driven SpriteKit renderer (Phase 4), `DuneIIInput` (Phase 5), the **native-macOS `duneii`** + **iOS `duneii-ios`** clients sharing everything via `DuneIIClient` (Phase 6), and `DuneIIAudio` incl. AdLib/MIDI music (Phase 7). 🎉 **No gameplay gaps remain** (see `FeatureParity.md`); the frontier is **presentation/Phase-6 polish + client QoL**.

## Active task

**▶ No active task — clean stopping point.** Most recent session (2026-06-06), newest first — full detail in `Documentation/History/2026-06-06.md`:

- **Right-click into fog = Move, never Attack** (`GameModel.isEnemy` requires `isUnveiled`).
- **Scrollable decorative map border** — the camera pans **16** game-pixels (one tile) past the playable edge (`Viewport.borderPx`); `GameScene.updateBorder` tiles the **concrete-slab tile** (`AssetStore.concreteTile` → `TileIDs.builtSlab`) around the 4-strip ring. (Earlier iterations: hazard stripe → 9-patch gold frame → concrete; history has the trail.) Two bugs fixed en route: `load()`'s keep-list orphaned `borderLayer` (added it); `gamePopover`'s `maxHeight`-only sizing collapsed Lists on macOS (now a definite height). Map-control buttons restyled neutral/translucent. New **`ClientTests`** target (`BorderRenderTests`) renders the real `GameScene` headlessly and asserts the border nodes are **attached to the scene**.
- **Right-click a player building → context popover** (no units selected; units-selected right-click still orders units). Shows state + actions (repair/upgrade/super-weapon, or the in-progress build's pause/resume/place/stop) + the buildable list. `BuildingContextMenu`/`BuildingMenuAnchor` (DuneIIClient), `GameModel.rightClickOpensBuildingMenu`, anchored at the click via a SwiftUI map-overlay point. **Popover anchoring is manual-verification owed** (AppKit/UIKit→SwiftUI coordinate mapping).
- **Floating top-right map controls** — moved Mentat/Options/Save/Load off the sidebar bottom bar into `MapControlsOverlay` (both clients).
- **Double-click selects all same-type units** (both clients). Pure `InputController.sameTypeGroup` + `GameModel.doubleClickSelectSameType` (player-owned/on-map/normal units of the clicked type, whole map; falls back to single-select otherwise). macOS `NSEvent.clickCount`; iOS same-tile double-tap (0.35 s). Input seam ⇒ neutrality + `InputTests`.
- **Update SwiftOPL3 dep** `956d440 → 935140c` (latest `main`; upstream added experimental `OPL_FLOAT`/`OPL_SIMD` engines behind compile flags — off in our build, default integer DSP unchanged). `swift package update` needs the tool sandbox disabled.
- **Ornithopter/carryall crash-wreck fixed.** `setAnimation` was a stub; now a faithful `Explosion_Func_SetAnimation` (`explosion.c:175`) via `Simulation.drainCrashAnimations`: **no wreck over a structure**, random 0/1 variant, `+2` over rock. Off the parity path ⇒ unit coverage (`TrackAndCrashTests`) + neutrality.
- **Winger drop shadows** (carryall/ornithopter/frigate). `ShadowMapping` (ports `g_paletteMapping1`) + `ShadowEffect.patch` + a new SpriteKitRenderer shadow layer (z 3); `FrameInfo.Unit.hasShadow`. Render golden `scena005-air-shadow-t0` + `ShadowEffectTests`.

(Earlier sessions are in History; the macOS/iOS client polish batches are in `History/2026-06-03.md`/`-05`/`-06`.)

## Next up (candidates)

- **Tick speedup** — design ready in `Architecture/Parallelization.md`. Conclusion (§8): **sequential wins**; the merged Round-3 work made the tick allocation/ARC-free (+35–42%). Further single-sim parallelism needs Instruments + an SoA data-layout change (a separate effort). The `SPEEDUP`/release strip of trace output is already in.
- **Presentation polish** — per-house spoken `%c` *announcement* voices (need new sim-emitted `SoundEvent`s → golden care; the acknowledge/under-attack/destroyed cues are done); the original selection-box `g_sprites[6]` sprite (we draw a plain outline); optional on-screen-only scope for double-click select.
- **Harness next levels** (`Architecture/ScenarioHarness.md`) — a **unit** decision-trace (`--parity-script-unit`) and Tier-3i semantic event-trace alignment, if a future divergence needs them.
- **iOS deploy** — `Scripts/build-ios.sh device` can hang at install/launch-over-USB in a headless context; the fast warm path is Xcode Run or `xcrun devicectl device process launch --device <name> com.lonelybytes.duneii` (see `Apps/duneii-ios/README.md`).

## Test status

`Scripts/check.sh` (`--full` = clean-build zero-warnings audit): **624 tests, all green**, clean `--full` build (0 warnings). iOS cross-compile clean (`Scripts/check-ios.sh`). **0 known issues.**

**Parity:** cross-engine scenario goldens for the full four-phase sim (11+ scenarios — movement/combat/structures/houses/teams, plus map-tile wall/slab goldens), a per-tick **RNG draw-stream golden** (`Random256`/`RandomLCG` byte-identical to the oracle), a **structure decision-trace** (opcode-identical EMC), and **render goldens** (pixel-exact via `SpriteKitRenderer.snapshot`) — all full matches. Detail + regeneration: `Architecture/ScenarioHarness.md` + `Testing.md`. Regen: `Scripts/gen-scenario-goldens.sh`, `Scripts/gen-render-goldens.sh`; rebuild the oracle with `Scripts/build-oracle.sh`.

**Environment quirk:** direct `exec` of `clang`/freshly-built binaries returns EPERM, and a relinked oracle binary must be re-signed — all handled inside `Scripts/` (insight `build-exec-eperm`). Adding/removing a `GameState` stored property warrants a clean `--full` build (stale-`.swiftmodule` layout trap; insight `build-gamestate-layout-stale-module`).

## Self-review tracker

Last review: **2026-06-03 at `dffaece`**. Next trigger: **+32 commits** (`git rev-list --count dffaece..HEAD`) or the next completed phase (`CLAUDE.md` → "Periodic self-review"). Durable outcomes from all past reviews are already folded into `CLAUDE.md` standing rules + `Documentation/Insights/` (e.g. `host-presentation-gap-not-sim`, `sim-rng-stream-unpinned-wobble`, `sim-isaiactive-contact-not-load`, `build-exec-eperm`, `build-gamestate-layout-stale-module`). The 2026-06-03 review's theme: a "missing" client feature is usually the sim already doing it while the host doesn't surface it. **Nothing new has risen to a standing rule recently.** Prior review points: `4438003` (2026-06-01), `b5caa09` (2026-05-31).

## Open decisions

All `Plan.v1.md` §8 decisions are resolved: single-package `Code` multi-target (swift-tools 6.3, macOS 26); `assetgen`-regenerated committed `Resources/`; OpenDUNE oracle tooling stood up; multi-window UI = **native macOS AppKit + SwiftUI** (non-Catalyst, pivoted 2026-05-31) with floating `NSPanel` tool windows. See `Plan.v1.md` §8.
