# A unit's per-step speed comes from the tile it's entering, not the tile it's on

**Finding:** `Unit_StartMovement` sets the speed for each one-tile step from the **landscape of the tile being entered** (the next tile in the unit's facing: `Tile_MoveByOrientation(position, orientation)` → `Map_GetLandscapeType` → `g_table_landscapeInfo[type].movementSpeed[movementType]`), not from the tile the unit currently sits on. It's called once per tile-step, so terrain is accounted for at the **start of every step**, including the first one of a move. A unit below half HP gets `speed -= speed/4` (non-winger).

**Why it matters:** when debugging "why is this unit's speed X here," look at the tile **ahead** of it (the one it's moving into), not under it. A change in speed mid-path is this per-step recompute as the unit crosses a terrain boundary — expected, not a bug. Using the current tile instead would be subtly wrong (and would diverge from the oracle on the first step onto different terrain).

**Evidence:** OpenDUNE `src/unit.c:1059` (`Unit_StartMovement`); our port `Code/Frameworks/DuneIISimulation/UnitMovement.swift` (`startMovement`); `Code/Tests/SimulationTests/MovementTerrainTests.swift` (a swap test proves the entered tile, not the current one, drives the start speed — wheeled sand 160 > rock 64). The `moving`/`move-trike`/`trooper` scenario goldens confirm it end-to-end over real `Map_CreateLandscape` terrain.

**How to apply:** treat the move speed as a property of the destination tile of the current step. When porting/altering movement, keep the speed source = the entered tile; don't "fix" a mid-path speed change.
