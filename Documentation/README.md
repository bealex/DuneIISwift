# Documentation

Top-level index. Start with the plan, then the architecture overview. The format docs are encyclopedic; read on demand. The history and insights are append-only records — they get richer with every feature.

## Plans (roadmap)

- [01.Initial.md][1] — P0–P8 phase plan, scope, success criteria.
- [02.P1-Complete.md][2] — P1 "format foundation" close-out.
- [03.P2-Rendering.md][3] — P2 plan, split into pure-Swift semantic models (slice 1) and the Mac Catalyst rendering app (slice 2).

Each subsequent plan file records what a phase actually shipped and what slipped forward.

## Architecture

- [Overview.md][4] — module graph, threading, asset-load & tick flows.
- [Testing.md][5] — per-layer testing strategy, coverage rule, what "tested" means.

## Formats

One file per on-disk format. Each doc contains: layout in our own words, worked byte-level example, pointer to the OpenDUNE source, Swift type name, testing strategy, and cross-links to related insights.

- [PAK.md][6] — container archive.
- [Palette.md][7] — 6-bit VGA palette (IBM.PAL et al).
- [CPS.md][8] — full-screen 320×200 images.
- [SHP.md][9] — sprite frame sets.
- [WSA.md][10] — pre-rendered animations.
- [ICN.md][11] — tile sets with sub-palette indirection.
- [FNT.md][12] — 4-bit packed bitmap fonts.
- [VOC.md][13] — Creative Voice audio.
- [MAP.md][14] — ICON.MAP terrain tile group index.
- [INI.md][15] — scenario and region config (`.INI`).
- [EMC.md][16] — compiled game script container.
- [XMI.md][17] — Miles XMIDI music.

Deferred to later phases: C55/ADL/PCS/TAN music banks, save format (`_SAVE00?.DAT`), TBL miscellany.

## Algorithms

- [Scenario.md][18] — `SCEN?00?.INI` → typed model.
- [Map.md][19] — 64×64 grid + `LandscapeType` classification.
- [ScenarioWorld.md][20] — typed world snapshot: scenario + stamped map + unit/structure queries.
- [RNG.md][24] — `Tools_Random_256` and the Borland LCG, bit-for-bit.
- Future: Format80 opcode trace, EMC VM semantics, pathfinding heuristics, spice-bloom / sandworm application, save format.

## History

Monthly changelog. One file per calendar month. Append-only.

- [2026-04.md][21] — P1 kickoff, decoders, `assetgen`.
- [README.md][22] — format and entry conventions.

## Insights

Distilled non-obvious findings, indexed by category. Every file answers a single question a future engineer would otherwise re-discover the hard way.

See [Insights/README.md][23] for the index and template. Start here when a feature surprises you.

## How to contribute new docs

See the "Feature workflow" section of `CLAUDE.md` at the repo root. The short version: design doc first, failing test second, implementation third, history + insight fourth.

[1]:	Plans/01.Initial.md
[2]:	Plans/02.P1-Complete.md
[3]:	Plans/03.P2-Rendering.md
[4]:	Architecture/Overview.md
[5]:	Architecture/Testing.md
[6]:	Formats/PAK.md
[7]:	Formats/Palette.md
[8]:	Formats/CPS.md
[9]:	Formats/SHP.md
[10]:	Formats/WSA.md
[11]:	Formats/ICN.md
[12]:	Formats/FNT.md
[13]:	Formats/VOC.md
[14]:	Formats/MAP.md
[15]:	Formats/INI.md
[16]:	Formats/EMC.md
[17]:	Formats/XMI.md
[18]:	Algorithms/Scenario.md
[19]:	Algorithms/Map.md
[20]:	Algorithms/ScenarioWorld.md
[21]:	History/2026-04.md
[22]:	History/README.md
[23]:	Insights/README.md
[24]:	Algorithms/RNG.md
