# What to do

Remaining work across the project, organised by scope. Kept as a living punch list — update as slices land. Last refreshed 2026-04-21 after P5 slice 6c (621+ green, economy fully wired for build panel).

See also:

- `CurrentState.md` — the active task + immediate-next-step for the next session.
- `Documentation/Plans/01.Initial.md` — authoritative phase plan.
- `Documentation/History/` — what actually shipped.

## Sizing key

- **XS** ≈ 1 commit, pure sim data
- **S** ≈ 1 session, 1 focused commit
- **M** ≈ 2–3 slices / a few sessions
- **L** ≈ 5+ slices, probably multi-phase

## Immediate P5 closure (small slices)

| # | Slice | What | Size | Why |
|---|-------|------|------|-----|
| 1 | **6d** HUD credits label | `Credits: N` SKLabelNode on `ScenarioScene`; default-credits seed for mission 1 | S | Makes the slice-6b/c economy visible |
| 2 | **STARPORT** | `Structure_GetBuildable` `-1` sentinel + `g_starportAvailable` runtime state + CHOAM trade UI | M | Closes the last buildable path |
| 3 | **Rally-point click** | Player right-click on map sets a factory's unit-spawn tile | S | UX polish over the anchor-tile default |
| 4 | **Yard visual BUSY state** | `Structure_UpdateMap` animated-tile frames — yards visibly under construction | S | Visual polish, sim parity |

## P5 → P4 bridges (gameplay that's still missing)

| # | Area | What | Size | Why |
|---|------|------|------|-----|
| 5 | **Spice/harvester income** | Harvester → refinery → credits-in. Other side of economy | L | Currently no way to earn credits |
| 6 | **Unit selection + orders** | Click unit, right-click to move/attack; selection rectangle for groups | L | Built units currently just sit there |
| 7 | **Victory / loss conditions** | Scenario win on quota or enemy wipe; loss on base destruction | M | Scenarios never end |
| 8 | **Sim-to-visual sync for HP/death** | Render hooks so damaged units show HP bars, dying units despawn cleanly | M | Noted in `CurrentState.md` Next up |
| 9 | **`buildCostRemainder` fractional smoothing** | Port OpenDUNE's per-tick accumulator for exact credit math | XS | Off-by-1-credit at completion now |
| 10 | **Per-tick HP decay for `degrades` flag** | The flag is set (slice 4c) but nothing consumes it yet | S | Completes the "degrades" loop |
| 11 | **Storage cap on credits** | Enforce `creditsStorage` ceiling when spice income lands | S | Pairs with harvester work |

## P5 polish / P6 groundwork

| # | Area | What | Size | Why |
|---|------|------|------|-----|
| 12 | **Unit info panel** | Selected unit's HP / type / action in the sidebar | M | Part of the "real HUD" item in `CurrentState.md` |
| 13 | **Minimap** | Top-right corner; click to pan camera | M | Part of the "real HUD" item |
| 14 | **Mouse hover tooltips** | Sidebar slot hover shows name + cost; map hover shows tile info | S | UX polish |
| 15 | **Slice 2.1 polish** | Intro WSA playback, jukebox + SoundFont, VOC voice, mentat briefing text, pan/zoom | M | Pre-existing deferred item |
| 16 | **Per-unit SHP rendering full pass** | Replace remaining marker fallbacks with real unit frames | S | Noted as item 9 in `CurrentState.md` Next up |

## Simulation parity + verification

| # | Area | What | Size | Why |
|---|------|------|------|-----|
| 17 | **Tick-parity golden harness** | Record OpenDUNE for N ticks; replay in our sim; diff pool state | L | Closes §6 Initial-plan goal |
| 18 | **BULLET.EMC script wiring** | Bullets currently detonate via scheduler shortcut; running the real script gives sonic-beam + flight frames | M | Cosmetic, sim-parity |
| 19 | **Sandworm `GetBestTarget`** | Separate `Unit_Sandworm_GetTargetPriority` (sand-only, movement-state weighted); slot 0x36 | S | Noted as item 4 in `CurrentState.md` Next up |
| 20 | **Scenario starting-credits defaults** | Mission 1 scenarios may not specify credits — apply house-info defaults | XS | Would otherwise start at 0 credits |

## P6 Save compatibility

| # | Area | What | Size | Why |
|---|------|------|------|-----|
| 21 | **Save round-trip test** | Fuzz-check `_SAVE001.DAT` → load → re-encode → identical bytes | M | §9 testing-strategy goal |
| 22 | **Save-chunk TEAM decoder** | Optional chunk not yet decoded | S | Needed for AI-aggressive saves |
| 23 | **Save writer** | Currently read-only; writer for saved-game snapshots | L | Required for P6 |

## P7 Campaign

| # | Area | What | Size | Why |
|---|------|------|------|-----|
| 24 | **House selection screen** | Choose Atreides/Harkonnen/Ordos | S | Start-of-campaign entry point |
| 25 | **Region map** | Dune II's overmap — pick next mission in the house's progression | M | Campaign progression |
| 26 | **Cutscene playback** | Full WSA intro / between-mission cutscenes | M | Pre-existing assets, needs player |
| 27 | **9-mission campaign glue** | Wire scenario progression → next region → next scenario | M | Depends on #24, #25 |

## P8 Polish

| # | Area | What | Size | Why |
|---|------|------|------|-----|
| 28 | **Accessibility + key remapping** | Configurable shortcuts, accessibility audit | M | Listed in Initial plan §8 |
| 29 | **Window / input handling** | Mac-native conventions, full-screen, resizing | S | Listed in Initial plan §8 |
| 30 | **Perf tuning** | Profile tick cost, tile-rendering batching | M | Listed in Initial plan §8 |

## What closes the "feels like Dune II" loop

In order of how much each unlocks:

1. **#5 harvester/spice income** — without it, the economy is one-way. Biggest remaining gameplay hole.
2. **#6 unit selection + orders** — without it, built units are decorative.
3. **#7 victory conditions** — without it, scenarios have no end state.
4. **#1 HUD credits label** — tiny, high-value sanity check.
5. **#12–13 unit info + minimap** — round out the HUD.

Everything else is polish, parity, or future-phase work.
