# The `duneii` client — verification UI, input, and debug toggles

`duneii` is the native-macOS game client (AppKit + SwiftUI, non-Catalyst): a SwiftUI main map window plus floating AppKit `NSPanel` tool windows. It is **our own verification UI**, not a reproduction of the original HUD. It drives the headless `Simulation` (advances ticks against wall-clock × speed), snapshots `makeFrameInfo()` each frame, and renders it via `SpriteKitRenderer`. All of the affordances below are **presentation-only** — they emit `Command`s or read `FrameInfo`/`GameState`; none change simulation behaviour except the two debug flags called out under *Debug toggles*, which default to the faithful setting and so stay golden-neutral.

Source: `Code/Apps/duneii/` — `GameModel` (the `@Observable` view-model + sim driver), `GameScene` (the SpriteKit map + mouse/keyboard), `ContentView`/`MapSpriteView`/`FirstMouseSKView` (hosting), `Panels` (the tool-window SwiftUI views), `ToolWindows`/`App` (the window manager).

## Windows

- **Main map** — a `GameScene` (SpriteKit) hosted in a `FirstMouseSKView`. The view **accepts the first mouse** (so a map click works while a tool panel holds focus) and **forwards `otherMouse*`** (middle button) to the scene, which `SKView` does not do by default.
- **Tool panels** (`NSPanel`, toggleable from the toolbar): **Selection** (the inspector), **Economy**, **Debug**, **Minimap**.

## Input model

The host (`GameModel`) owns the world model and resolves each gesture to a `Command` for the `InputController`, then drains the queue into the sim between ticks.

- **Left-click** (resolved on mouse-**up**, so a press-drag-release can be a box) — selects the unit/structure under the cursor (`pick`). On **bare ground** (nothing selectable) it instead **inspects that tile** (see *Tile inspector*). While an order is armed, the left-click supplies the target.
- **Left-drag** — **drag-select a group**: rubber-bands a box (green) and selects every player-owned, on-map, normal unit inside it (`GameModel.dragSelect` → `InputController.selectGroup`). Orders then apply to the whole group; each selected unit gets a white selection outline (one box per unit), and the inspector header shows `×N`. Suppressed while a mode (placement / missile-target / armed order) is active. *(The original Dune II selects one unit at a time — group select is a verification-client convenience.)*
- **Right-click** — issues the contextual order to **every selected unit**: an **enemy** tile → `Attack`, else → `Move`; a **single** selected **harvester** → `Harvest` (its `actionsPlayer[0]`; a multi-unit group never harvests). (`InputController.rightClick(enemyTarget:harvester:)`, the facts resolved host-side.)
- **Keyboard order arming** — `a`/`m`/`h`/`r` arm Attack/Move/Harvest/Retreat (the cursor becomes a crosshair; the next left-click is the target); `s` stops; `Esc` cancels the active mode (target-select / placement / missile-targeting) else deselects; `+`/`-` zoom; arrows scroll.
- **Middle mouse** — **drag pans** the map (hand-tool: content follows the cursor); a plain **middle-click recentres** on the clicked point.
- **Placement mode** — a finished construction-yard structure shows a footprint preview that follows the cursor; left-click places (on a valid spot), right-click/`Esc` cancels.
- **Missile target-select** — a ready palace's "Launch" arms a death-hand target click (see `Algorithms/PalaceSuperWeapon.md`).

## Tile inspector

Left-clicking a tile with no unit/structure on it shows that tile's parameters in the **Selection** inspector (when nothing is selected): landscape name (Sand / Rock / Spice / Dune / Mountain / Concrete / Wall / Rubble / Spice bloom…), the packed index, ground & overlay tile ids, spice, owner (only meaningful on concrete/wall/structure tiles), fog state, and buildability. Derived live each tick by `GameModel.refreshTileInfo` from `GameState.map` via `DefaultMapPrimitives.landscapeType` + `LandscapeInfo.isValidForStructure`; it clears the moment a unit/structure is selected.

## Selection inspector

For a selected entity: name/house/tile/health, then context sections — the unit's player **action menu** (`actionsPlayer`), a player structure's **Repair/Upgrade** toggles, a **starport** CHOAM order list, a **palace** super-weapon Launch button, and a **factory** build selector / progress / "Place it". (Deselect is `Esc`; there is no Deselect button.)

## Economy panel

One card per house with credits/storage and the power balance. Lists **only houses actually on the map** (≥1 used unit or structure — `GameModel.housesOnMap`), so houses merely activated for the economy via `[HOUSES]` with no presence are not shown. The Debug *Show all economies* toggle gates whether non-player houses appear at all.

## Hints

A transient banner at the bottom of the map (`GameModel.notice`, auto-cleared after ~3 s) surfaces the `GUI_DisplayHint`-family player notices, all **derived each frame from the player's economy + factory state** (no new sim events): **construction complete** (a player factory's product becomes ready — edge-triggered per factory), **low power** (production < usage — edge-triggered), and **insufficient funds** (a build/starport order refused for cost). Faithful triggers, our own strings; presentation-only, so the sim is untouched.

## Debug toggles

The Debug panel. Toggles marked *(debug)* change simulation behaviour; both default to the faithful setting, so the goldens stay byte-identical.

| Toggle | Default | Effect |
|---|---|---|
| **Fog of war** | off | Render-only: draw the player's fog veil. Does **not** touch AI vision. |
| **AI fog of war** *(debug)* | off | Give the AI a fog so it only attacks after the player makes contact — see `Architecture/AIFogOfWar.md`. |
| **Follow unit limit** *(debug)* | on | Enforce each house's scenario `MaxUnit` cap in `Unit_Allocate` (`GameState.enforceUnitLimit`). Off ⇒ build past the cap. duneii loads each house's real `MaxUnit` (default 39), not a pinned 1000, so "follow" enforces the actual limit. |
| **Show all economies** | off | Show every (on-map) house in the Economy panel, not just the player's. |
| **Health bars (units + buildings)** | on | Draw the per-object health/state overlay on the map. |

Speed (0.5×–4×) and pause are separate toolbar controls; the two-clock model lets the sim run sped-up deterministically.

## Audio

Combat/explosion effects are sim-emitted `SoundEvent`s resolved through `VoiceTable` (the `+` effect VOCs). The unit **acknowledgement voices** (`g_table_voices` 17–22, the language-`%c`=Z English set) are host-played: selecting a player unit plays REPORT1 (foot) / REPORT2 (vehicle) — `unit.c:1730`; ordering it plays the action's voice for a foot unit (move→MOVEOUT, attack/retreat→OVEROUT, harvest→REPORT3) or a random REPORT3/AFFIRM for a vehicle — `viewport.c:182` (the vehicle pick uses a **host** random, never the sim RNG, so determinism/goldens are untouched). Structure selection keeps the plain CLICK. Still seams: the per-**house** spoken announcement voices (`%c`=house: build-complete, under-attack, deploy, …), which need sim-emitted announcement events; music; distance attenuation from `SoundEvent.position`.

## Parity note

The client is out of `FeatureParity.md`'s scope (presentation). The only simulation-affecting switches are the two *(debug)* flags, which live on `GameState`, default to the original 1.07 behaviour, and draw no RNG — so every scenario/render golden is unchanged with them at their defaults. See the `feedback_golden_per_feature` rule: presentation/no-oracle features are verified by neutrality + unit tests.
