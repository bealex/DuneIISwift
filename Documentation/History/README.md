# History

Append-only changelog, **one file per active day** (`YYYY-MM-DD.md`). One bullet per change, imperative mood, with file references. Add a bullet with `Scripts/log-history.sh "<text>"` (it writes today's file and keeps the index below current). Newest day first.

Do not rewrite a past entry; if one is wrong, add a dated correction. The periodic self-review (CLAUDE.md) rereads the **recent daily files** + `Insights/` for recurring lessons.

## Days

- [2026-05-31](2026-05-31.md) — Phase 4 render harness: headless `SpriteKitRenderer.snapshot` capture + the pixel-exact `RenderGoldenTests` render-golden harness.
- [2026-05-30](2026-05-30.md) — the big day: full unit-vs-unit combat parity; the entire structures + teams + house-economy subsystems → **Phase 3 closed**; then Phase 4 renderer brought up (`FrameInfo` seam → `FrameComposer` → `SpriteKitRenderer` → `mapview`), reported mapview-bug fixes, air-unit winger + tile-overlay/fog.
- [2026-05-29](2026-05-29.md) — map-from-seed (`Map_CreateLandscape`); Phase 1 finish; native primitives + stat tables; the EMC VM + disassembler; unit movement bit-exact vs OpenDUNE; pathfinder; the `Script_Unit_Fire` projectile path.
- [2026-05-28](2026-05-28.md) — project reset + `Plan.v1`; Phase 0 scaffold (SwiftPM graph, docs); Phase 1 format/codec ports (Format80/40, PAK/SHP/CPS/ICN/WSA/EMC…) + asset export + the `rendertest` app; the scenario/map/sprite-init design.
