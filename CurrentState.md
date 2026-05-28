# Current State

**Branch:** `rebuild/core-engine` (off `main`). **Plan of record:** `Documentation/Plan.v1.md`. **Architecture:** `Documentation/Architecture/Overview.md`.

## Active task

**Phase 1 — `DuneIIFormats`.** Start with the Format80 codec. Immediate next step: write `Documentation/Formats/Format80.md` (own-words description + pointer to OpenDUNE `src/codec/format80.c`), then implement `Code/Frameworks/DuneIIFormats/Codec/Format80.swift` as a pure `decode`/`encode` on `Data`, with round-trip tests + a real-data test (short-circuiting when the install is absent). Then Format40, then PAK.

## Next up (queue)

- **Phase 1 (cont.)** — Format40, PAK, ICN/tiles, SHP, CPS, palette, FNT, WSA, VOC, INI, the SAVE IFF/FORM reader, the EMC reader + `emc-disasm`. Rebuild `assetgen` to regenerate `Resources/`. Design-on-paper each under `Documentation/Formats/` first.
- **Phase 2 — `DuneIIWorld` + `DuneIIContracts`.** Model, stat-table port, `GameState`, both RNGs bit-exact, scenario `.INI` load, our save round-trip, original-save converter. Define `FrameInfo`/`Command`/`SoundEvent`.
- **Phase 3 — `DuneIISimulation`.** Loop + clocks → primitives → one unit type end-to-end → economy → structures → houses/teams/AI → projectiles/explosions. State machines = exact EMC transcription, verified by Tier-2a decision traces.
- **Phases 4–5 — `DuneIIRenderer` + `rendertest` + `DuneIIInput`.**
- **Phase 6 — hosts + multi-window UI.**
- **Phase 7 — `DuneIIAudio`.**

## Recently completed

- Reset to a core-engine rebuild; wrote `Documentation/Plan.v1.md` (commit `9b8ee1f`). See History 2026-05.
- Phase 0 docs: CLAUDE.md rewrite + Architecture/{Overview,Testing,ParityHarness}.md + this file + History/Insights (commit `68301f4`).
- Phase 0 scaffold: `Code` SwiftPM graph — 7 libraries + `assetgen` + `duneii-headless` + per-module CLAUDE.md. Clean build, zero warnings, 4 scaffold tests green.

## Test status

`cd Code && swift test`: **4 tests, all green** (Phase 0 scaffold link tests). Clean build (`swift package clean && swift build`): zero warnings.

## Open decisions (from Plan.v1.md §8)

1. Package layout — proceeding with `Code` single-package multi-target as planned (swift-tools 6.3, macOS 26). Adjust if desired.
2. `assetgen` + `Resources/` regenerate fresh in Phase 1 (planned).
3. OpenDUNE oracle tooling stood up in Phase 1–2.
4. Multi-window UI tech (Catalyst `UIScene` vs AppKit) — decide at Phase 6.

## Self-review tracker

Baseline tag: `selfreview-phase0` (set at the Phase 0 scaffold commit). Commits since = `git rev-list --count selfreview-phase0..HEAD`. Trigger: each completed phase, or every 32 commits. See CLAUDE.md → "Periodic self-review." Phase 0 review: nothing recurrent yet (first phase) — no new instructions.
