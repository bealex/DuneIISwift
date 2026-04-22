---
name: GetInfo 0x0B reads currentDestination, not targetMove
description: Script_Unit_GetInfo subcase 0x0B checks per-step pixel destination, not the player's ultimate goal. Misreading it makes MOVE handlers loop forever.
type: insight
---

`Script_Unit_GetInfo` (unit slot `0x00`) subcase `0x0B` in OpenDUNE (`src/script/unit.c:968`) is:

```c
case 0x0B: return (u->currentDestination.x == 0 && u->currentDestination.y == 0) ? 0 : 1;
```

It is *not* checking `targetMove`. These are two different fields:

- **`targetMove`** — encoded index (usually a tile) of the player's *ultimate* move goal. Set once by `orderMove` and cleared when the route finishes.
- **`currentDestination`** — pos32 pixel coordinates of the *per-step* sub-goal the route-follower is currently walking toward. Set by the scheduler each time it pulls a step off the route array; cleared on arrival at that sub-goal.

On tick 1 of a fresh MOVE order, `targetMove` is non-zero but `currentDestination` is still `(0, 0)` (cleared by `Unit_SetAction`'s `switchType == 1` branch at `src/unit.c:516`). OpenDUNE's MOVE handler, at UNIT.EMC word 637, reads subcase `0x0B` to decide:

- `0` ⇒ "no in-flight step — set up the move" ⇒ fall through to `CalculateRoute`
- `1` ⇒ "already moving — wait" ⇒ `Delay(10)` and loop back

So misreading `targetMove` here returns 1 at the wrong time and the script never advances past the wait. Any bug that makes the MOVE handler "do nothing but burn ticks" after an `orderMove` — speed=0, no pathfinding trace, no visible motion — should check this subcase first.

Cross-references:
- Port: `Code/Core/Sources/DuneIICore/Scripting/Functions.swift` `makeGetInfoUnit` case `0x0B`.
- Test: `EmcHostUnitFunctionsTests.swift` `getInfoSubcase0BChecksCurrentDestination`.
- Related: `Documentation/Algorithms/EmcDrivenSetSpeed.md` traces the full breakage chain (this bug kept CalcRoute from running, which in turn kept `Unit_StartMovement`'s SetSpeed from firing).
