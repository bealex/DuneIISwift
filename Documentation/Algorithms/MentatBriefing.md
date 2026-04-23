# Mentat briefing — pre-scenario intro screen

Status: Drafted 2026-04-23 (slice 1 — face backdrop + briefing WSA overlay + boot-flow wiring; text + voice + mouth animation land in follow-up slices).

The Mentat briefing is Dune II's post-mission-select, pre-scenario screen: the player's house Mentat (Cyril for Harkonnen, Radnor for Atreides, Ammon for Ordos) introduces the upcoming mission with a voice line and animated face while the scenario's `BriefPicture` (e.g. `HARVEST.WSA`) plays in the sub-screen. This port lands the shell first — voice sync, mouth animation, and the English briefing text follow once their assets / sources are fully traced.

References:
- OpenDUNE `src/gui/mentat.c:405..457` — `GUI_Mentat_Show()` main display + widget loop.
- OpenDUNE `src/gui/mentat.c:462..481` — `GUI_Mentat_ShowBriefing()` entry.
- OpenDUNE `src/gui/mentat.c:494` — house → CPS filename: `snprintf("MENTAT%c.CPS", g_table_houseInfo[houseID].name[0])`.
- OpenDUNE `src/gui/mentat.c:553..695` — `GUI_Mentat_Animation(speakingMode)` eye/mouth/shoulder animation.

## 1. Slice breakdown

- **Slice 1 (this doc) — shell**: house-correct `MENTAT{A,H,O,…}.CPS` backdrop, scenario `BriefPicture` WSA overlay, click-to-continue, boot flow `Intro → Mentat(scenarioName) → Scenario(scenarioName)`. No text, no voice, no mouth animation.
- **Slice 2 (shipped 2026-04-23) — animation**: ported `GUI_Mentat_Animation` into `MentatAnimator` (pure struct, value-typed, `Sendable`, 14 unit tests) plus scene wiring that loads `MENSHP{H,A,O,M}.SHP`, slices the 15 frames into eyes/mouth/shoulder/other, and positions them at per-house offsets from `s_mentatSpritePositions`. Scene drives the animator at 60 Hz (1 GUI tick / render frame) with a per-session seeded `BorlandLCG` so each mission has visibly different idle cadence. Shoulder is static; mouth + eyes cycle by OpenDUNE rules; "other" (Atreides book / Ordos ring) alternates frame 0 ↔ 1 on house-specific timers. Harkonnen's "other" is effectively dormant (matches OpenDUNE's 300*60-tick reschedule). Slice 2's `speakingMode` is pinned to `.speaking` since there's no voice yet — slice 3 will gate it on real playback state.
- **Slice 3 — voice + text**: wire `DuneIIRendering.Voice.play(named:)` on mentat enter; decode briefing text from the OpenDUNE string table (`STR_HOUSE_…FROM_THE_DARK_WORLD_OF_GIEDI_PRIME_…` at `src/table/strings.h:412`, 40 strings per house indexed by `houseID * 40 + campaignID * 4 + 4`). Voice-file naming pattern still needs archaeology — first stab is `BRID{campaign}{houseID}.VOC` but that's unverified.

## 2. Slice 1 — architecture

### 2.1 `MentatScene` inputs

```swift
MentatScene(
    assets: AssetLoader,
    playerHouseID: UInt8,          // drives MENTAT{letter}.CPS
    scenarioName: String,          // "SCENA001.INI"
    briefingWsaName: String?       // scenario.briefing.briefPicture (e.g. "HARVEST.WSA")
)
```

House → CPS letter mapping mirrors OpenDUNE's `g_table_houseInfo[houseID].name[0]`:

| House ID | Name | CPS |
|---|---|---|
| 0 | Harkonnen | `MENTATH.CPS` |
| 1 | Atreides | `MENTATA.CPS` |
| 2 | Ordos | `MENTATO.CPS` |
| 3 | Fremen | `MENTATF.CPS` (rare; present in some installs) |
| 4 | Sardaukar | `MENTATS.CPS` |
| 5 | Mercenary | `MENTATM.CPS` |

If the chosen CPS is missing from the install, fall back through the list so a stripped install still renders *something* (same resilience the existing stub uses).

### 2.2 WSA overlay

Each scenario's `[BASIC] BriefPicture=` names a `.WSA` animation that plays in the mentat's sub-screen (the round "monitor" on the mentat's desk). For slice 1 we:

1. Load the WSA via `AssetLoader.loadWsa(named:)`.
2. Play it in a tight SpriteKit loop (~10 fps, matching OpenDUNE's `GUI_Mentat_Loop` frame-advance at `mentat.c:1244`).
3. Position it on the CPS backdrop — center it on the mentat's "screen" area; the sub-screen's sprite coordinates come from `s_mentatSpritePositions[houseID]` at `src/gui/mentat.c:40..47` (slice 2 will place it precisely; slice 1 uses a fixed centre).

### 2.3 Boot-flow wiring

`GameController.advance(from:)` currently goes `Intro → Scenario` directly with MainMenu + Mentat disconnected. Slice 1 adds:

- `Route.mentat` becomes `case mentat(scenarioName: String)` so the coordinator carries the target scenario through the briefing.
- Intro exit → `routeToDefaultScenarioViaMentat()` which picks the default scenario, routes to `.mentat(name)`.
- Mentat exit → `route(to: .scenario(name))` with the same name.

### 2.4 Click-to-continue

`MentatScene.mouseDown` → `coordinator.advance(from: self)`. Future slices gate this on `voiceFinished && textFinished` but slice 1 accepts a click immediately.

### 2.5 Player-house resolution

For slice 1 the player house is inferred from the scenario filename:
- `SCENA###.INI` → Atreides (1)
- `SCENH###.INI` → Harkonnen (0)
- `SCENO###.INI` → Ordos (2)

Filenames without the letter-prefix default to the scene's `playerHouseID` (already defaulted to Atreides elsewhere). This is a stop-gap — once campaign selection lands (P7), player house becomes an explicit session setting.

## 3. Manual-verification checklist (slice 1)

Scene-rendering is manual per `DuneIIRendering/CLAUDE.md`. Run with a real install (mission 1 by default):

- [ ] Launch `duneii`. Intro plays, then transitions into a Mentat screen (not directly into the map as before).
- [ ] Mentat backdrop is `MENTATA.CPS` (Atreides for SCENA001); face is recognisable.
- [ ] The scenario's `BriefPicture` (mission 1 = `HARVEST.WSA`) animates in the sub-screen region — frames cycle at ~10 fps, looping.
- [ ] Caption "Mentat briefing — click to continue" visible at the bottom.
- [ ] Single left-click anywhere advances to the scenario scene (the map + sidebar appear, mission 1 starts).
- [ ] Right-click and keyboard are no-ops (slice 1 scope — slice 2 will add skip/escape).
- [ ] With a stripped install missing `MENTATA.CPS`, the scene falls back to the first available `MENTAT{A,H,O,M}.CPS`; no crash.
- [ ] With a stripped install missing `BriefPicture` WSA, the mentat still renders — just without the sub-screen animation.

## 4. Tests (slice 1)

- `MentatSceneTests.cpsForHouse` — `MentatScene.cpsName(forHouse: 1) == "MENTATA.CPS"`, etc.
- `MentatSceneTests.houseFromScenarioName` — `MentatScene.playerHouse(forScenarioName: "SCENA001.INI") == 1`, `"SCENH007.INI" == 0`, `"SCENO015.INI" == 2`.
- `GameControllerTests.bootFlowRoutesViaMentat` — install-gated check that `GameController.start()` lands on a `MentatScene` (not `ScenarioScene`) when an install is present.

No scene-rendering tests (sandbox can't drive SpriteKit).

## 5. Known follow-ups

- **Slice 2**: port `GUI_Mentat_Animation` — cycling mouth sprite, blinking eyes, shoulder / house-object animation with house-specific timers (Harkonnen fixed 300-tick interval, Atreides / Ordos random 60..180).
- **Slice 3**: decode briefing text from the OpenDUNE string table + wire voice playback. Voice-file naming pattern unverified (candidates: `BRIEF{n}.VOC`, `BRID{n}.VOC`, `{HOUSE}B{campaign}.VOC`) — needs archaeology on an actual install or a decompiled `MESSAGE.ENG`.
- **Skip / escape key**: OpenDUNE treats any key as "advance text line"; once textDone is true, any key exits. Our slice 1 just treats any click as exit.
