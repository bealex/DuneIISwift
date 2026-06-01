# `Unit_RemoveFog` only lifts the player's fog for **player-allied** units

**Finding:** `Unit_RemoveFog` (`unit.c:1217`) reveals the player's fog around a unit **only if that unit is allied to the player** — `if (!House_AreAllied(Unit_GetHouseID(unit), g_playerHouseID)) return;`. Fog is player-only, so an enemy unit must **not** unveil the player's fog around itself. (It also early-returns for off-map / `0xFFFF` / `0:0` position and a `fogUncoverRadius` of 0.) Our port was missing the allied check.

**Why it matters:** Without it, **every enemy unit unveils the player's fog around its own tile** each time its script runs `Script_Unit_RemoveFog`. Two visible bugs, one cause:
1. **Render** — with "Fog of war" on, the player sees *all* enemy units (each sits on a tile it just self-revealed).
2. **AI fog of war / contact** — `Unit_UpdateMap` on a now-unveiled enemy tile calls `Unit_HouseUnitCount_Add(enemy, player)` → that is "the player sighted an enemy" → `aiFogReveal` fires for every enemy house at once, so the AI commits immediately and the `aiFogOfWar` toggle "does nothing."

Corollary, also faithful: an enemy on a **fogged** tile has its `seenByHouses` **zeroed** (`Unit_UpdateMap` → `Unit_HouseUnitCount_Remove`, the `g_dune2_enhanced` pin). So a turret/unit can only target an enemy on an *unveiled* tile — a test that places a "seen" enemy must put it on an unveiled tile, or the next tick un-sees it.

**Evidence:** `Frameworks/DuneIIWorld/State/GameState+Fog.swift` `unitRemoveFog` (now has the allied check). Caught by the **`fog` scenario golden** (`Tests/ScenariosTests/Fixtures/fog.ini` + the `veil` field added to the `[DUMPTILES]` dump): a Harkonnen base + Ordos soldiers at increasing distances — before the fix our `veil` diverged at tick 1 (we unveiled tiles 5–10 away that the oracle kept fogged). `StructureScriptTests.turretFiresAtEnemy` now unveils the enemy tile.

**How to apply:** fog reveal (`Unit_RemoveFog` / `Structure_RemoveFog` / the continuous `Unit_UpdateMap(1)` radius-1) is **player-allied only** — never reveal the player's fog around an enemy. When a golden needs a unit to stay "seen" across ticks, its tile must be unveiled (else `Unit_UpdateMap` zeroes `seenByHouses`). Trace fog by adding `veil` (isUnveiled) to the per-tick tile dump and diffing vs the oracle.
