# History

Append-only changelog, **one file per active day** (`YYYY-MM-DD.md`). One bullet per change, imperative mood, with file references. Add a bullet with `Scripts/log-history.sh "<text>"` (it writes today's file and keeps the index below current). Newest day first.

Do not rewrite a past entry; if one is wrong, add a dated correction. The periodic self-review (CLAUDE.md) rereads the **recent daily files** + `Insights/` for recurring lessons.

## Days

- [2026-06-06](2026-06-06.md) — 
- [2026-06-05](2026-06-05.md) — 
- [2026-06-03](2026-06-03.md) — 
- [2026-06-02](2026-06-02.md) — faithful Pause/Resume buttons for a factory build in `duneii` (mirrors OpenDUNE's `STR_D_DONE`/`STR_ON_HOLD` GUI clicks): a held build resumes only once the house can afford it, never auto-resumes.
- [2026-06-01](2026-06-01.md) — `duneii` presentation perf from a CPU-trace read: a shared `FrameThrottle` rate-limits the sandworm-shimmer texture rebuild and the steady-state HUD derivations (~10 Hz), both golden-neutral at the default.
- [2026-05-31](2026-05-31.md) — a broad day. **Render:** `snapshot` capture + the pixel-exact `RenderGoldenTests` harness, tile-overlay transparency, partial fog soft edges, sandworm shimmer (CoreGraphics blur) — world content gap-free. **Parity:** wall-destruction + slab map-tile goldens (+ `[DUMPTILES]`), then **corrected** a wrong claim — concrete slabs ARE destructible (`TILE_DAMAGE`). **Phase 5 input:** `DuneIIInput` (selection + order controller) + mapview mouse/keyboard selection + a properties/commands inspector. **Phase 7 audio:** `SoundEvent` seam + `DuneIIAudio` low-latency polyphonic `AVAudioEngine` sink, wired into mapview. Also moved History to per-day files.
- [2026-05-30](2026-05-30.md) — the big day: full unit-vs-unit combat parity; the entire structures + teams + house-economy subsystems → **Phase 3 closed**; then Phase 4 renderer brought up (`FrameInfo` seam → `FrameComposer` → `SpriteKitRenderer` → `mapview`), reported mapview-bug fixes, air-unit winger + tile-overlay/fog.
- [2026-05-29](2026-05-29.md) — map-from-seed (`Map_CreateLandscape`); Phase 1 finish; native primitives + stat tables; the EMC VM + disassembler; unit movement bit-exact vs OpenDUNE; pathfinder; the `Script_Unit_Fire` projectile path.
- [2026-05-28](2026-05-28.md) — project reset + `Plan.v1`; Phase 0 scaffold (SwiftPM graph, docs); Phase 1 format/codec ports (Format80/40, PAK/SHP/CPS/ICN/WSA/EMC…) + asset export + the `rendertest` app; the scenario/map/sprite-init design.
