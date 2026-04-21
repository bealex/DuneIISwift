# Target acquisition — `Unit_FindBestTargetEncoded` + friends

Status: Drafted 2026-04-20 (P4 Phase 4 — first slice: target selection, pre-combat).

A unit deciding *what to shoot next* runs through three nested routines in OpenDUNE:

1. **Pool sweep** — `Unit_FindBestTargetUnit` / `Unit_FindBestTargetStructure` walk the live pools filtered by (very loose) LOS / distance rules.
2. **Priority score** — `Unit_GetTargetUnitPriority` / `Unit_GetTargetStructurePriority` collapse each candidate into a single `uint16` that composes target class, distance, and LOS/fog gates.
3. **Choose kind** — `Unit_FindBestTargetEncoded` compares the best unit to the best structure and returns the winning encoded index.

The whole call chain is a **pure read** over the pools. No slot is mutated in the standard modes; only `mode == 4` has the side effect of stamping `u->originEncoded` with the unit's current tile. That side-effect lives on the `Unit_FindBestTargetUnit` branch, not the dispatcher — we keep it there.

References:

- `src/unit.c:743` — `Unit_GetTargetUnitPriority`.
- `src/unit.c:923` — `Unit_FindBestTargetUnit`.
- `src/unit.c:2275` — `Unit_FindBestTargetStructure` (static).
- `src/unit.c:2396` — `Unit_FindBestTargetEncoded`.
- `src/unit.c:2562` — `Unit_GetTargetStructurePriority`.
- `src/script/unit.c:79` — `Script_Unit_FindBestTarget` (slot 0x1C) — thin wrapper.
- `src/script/unit.c:96` — `Script_Unit_GetTargetPriority` (slot 0x1D) — thin wrapper.

## 1. New fields on `UnitInfo` / `StructureInfo`

The scoring functions read four per-type fields that we haven't ported yet:

- `UnitInfo.priority: Bool` — from `ObjectInfo.flags.priority`. When `false`, the unit is never considered as a target (bullets, missiles — they have `priority = false`).
- `UnitInfo.targetAir: Bool` — from `ObjectInfo.flags.targetAir`. When a candidate is an air unit (`MovementType.winger`), only attackers whose own `targetAir == true` can target it.
- `UnitInfo.priorityBuild: UInt16` — from `ObjectInfo.priorityBuild`. The "how badly the AI wants to build this" score.
- `UnitInfo.priorityTarget: UInt16` — from `ObjectInfo.priorityTarget`. The "how badly someone wants to shoot this" score.
- `StructureInfo.priorityBuild: UInt16` + `StructureInfo.priorityTarget: UInt16` — same concept, from `ObjectInfo.priorityBuild` / `priorityTarget` on the structure side.

Data: extracted row-by-row from `src/table/unitinfo.c` + `src/table/structureinfo.c`. Numbers pinned inline in the Swift tables, with the source line range in a comment.

## 2. New host fields

We need two optional callbacks and one optional field on `Scripting.Host`:

- `playerHouseID: UInt8?` — the "local player" identity. `House_AreAllied` uses it to treat all non-player houses as implicit allies of each other (match OpenDUNE's `g_playerHouseID` global). `nil` → the alliance check degrades to "only strict equality is allied", which matches the pre-P4 behaviour for tests that don't care.
- `isValidPosition: ((UInt16) -> Bool)?` — packed-tile → in-map-bounds predicate. `nil` defaults to `true` (matches the typical 64×64 full-map scenario; mission edge shrinks land later). Invoked from `Unit_GetTargetUnitPriority` and by the priority functions to gate "on map" candidates.
- `isPositionUnveiled: ((UInt16) -> Bool)?` — packed-tile → fog-cleared predicate. `nil` defaults to `true` (`g_debugScenario == true` equivalent). Only used by the WINGER-vs-player branch.

All three are plumbed from the caller (tests build a `Host` directly; `ScenarioScene` will populate them once fog + map bounds become real).

## 3. `House_AreAllied(a, b, playerID)`

Port of `src/house.c:353`. Pure static function on a new `Simulation.House.areAllied(_:_:playerHouseID:)`:

```
if a == HOUSE_INVALID || b == HOUSE_INVALID: false
if a == b: true
if a == FREMEN || b == FREMEN: return (other == ATREIDES)
return (a != playerID && b != playerID)
```

We treat `HOUSE_INVALID` as `0xFF`, `ATREIDES = 0`, `FREMEN = 4` (from `HouseType` enum). When `playerHouseID == nil`, only the `a == b` path returns `true`; everything else falls through to `false`. That's the conservative choice for the pre-player-wired unit tests we already have.

## 4. `Unit_GetTargetUnitPriority(attacker, target, host)`

Exact port of `src/unit.c:743`:

1. Returns `0` when `attacker == target`, target isn't allocated, hasn't been seen by the attacker's house, or when they're allied.
2. Returns `0` when the target's `priority` flag is `false`.
3. Winger targets: if the attacker can't `targetAir`, return `0`. If `target.houseID == playerHouseID` *and* the target's tile isn't unveiled (fog mask), return `0`.
4. Returns `0` when the target is off-map.
5. Computes `distance = distanceRoundedUp(attacker, target)`.
6. If the *attacker* is off-map, cap to fireDistance: `if target.fireDistance >= distance: return 0`. (Yes, OpenDUNE uses the **target's** fireDistance here — that's by design, for sandworms/sonic tanks scooping bonuses from afar.)
7. `priority = targetInfo.priorityTarget + targetInfo.priorityBuild`. If `distance != 0`, `priority = (priority / distance) + 1`.
8. Clamp at `0x7D00` and return.

## 5. `Unit_GetTargetStructurePriority(attacker, target, host)`

Port of `src/unit.c:2562`, almost identical shape:

1. Return `0` on allied-house or not-yet-seen.
2. `priority = priorityBuild + priorityTarget`. Distance-divide when `distance != 0`.
3. Clamp at `32000` (explicit `min`, not `0x7D00`).

## 6. `Unit_FindBestTargetUnit(attacker, mode, host)`

Port of `src/unit.c:923`:

- Stamp `attacker.originEncoded` when it's 0 (encode attacker's current tile).
- Otherwise, decode `originEncoded` back into a tile32 position for `mode == 2`.
- `distance = fireDistance << 8`; if `mode == 2`, shift again.
- Walk the pool (`Simulation.PoolQuery` with `houseID = 0xFF` "any", `type = 0xFF` "any"):
  - For mode 1: skip candidates farther than `distance` from the attacker's *current* position.
  - For mode 2: skip candidates farther than `distance` from `originEncoded` tile.
  - For modes 0 and 4: no distance gate.
- Accumulate the highest-scoring candidate via `GetTargetUnitPriority`. OpenDUNE uses **signed** comparison (`(int16)priority > (int16)bestPriority`); the clamp at `0x7D00` keeps us inside the signed-positive range, so in practice the cast is only load-bearing when every candidate has `priority == 0` (then `best = NULL`).
- Return `NULL` when `bestPriority == 0`, else the winner.

**Side effect**: the `originEncoded` stamp is a write to the attacker slot when originEncoded was 0. This is the one place where the "best-target" read chain mutates state; we preserve it.

## 7. `Unit_FindBestTargetStructure(attacker, mode, host)`

Port of `src/unit.c:2275`:

- `position = Tools_Index_GetTile(attacker.originEncoded)` (note: assumes originEncoded is stamped — the unit variant above handles that).
- Walk the structure pool. Skip slabs (type 0, 1) and walls (type 14).
- For each candidate, compute `curPosition = structure.position + layoutTileDiff[layout]` (layout-centered tile for priority math).
- Mode 1 gates via `distance(attacker.position, curPosition) > fireDistance << 8`.
- Mode 2 gates via `distance(origin, curPosition) > fireDistance << 9`.
- Modes 0 and 4 skip the gate (but mode 2 falls out because `mode != 1 && mode != 2 && mode != 0 && mode != 4` → `continue`; careful around that inverted check in OpenDUNE).
- Accumulate via `GetTargetStructurePriority`. Uses `>=` (not `>`) — so later matches at equal priority win. Match byte-for-byte.

### 7.1 `layoutTileDiff`

Table indexed by `StructureLayout`. OpenDUNE `src/table/structureinfo.c` defines:

```
s1x1: {0, 0}    s2x1: {128, 0}   s1x2: {0, 128}    s2x2: {128, 128}
s2x3: {128, 256}   s3x2: {256, 128}   s3x3: {256, 256}
```

These are pos32 offsets in OpenDUNE units (one tile = 256 in pos32). We add them as a tiny static table on `StructureInfo`.

## 8. `Unit_FindBestTargetEncoded(attacker, mode, host)`

Port of `src/unit.c:2396` — the top-level dispatcher:

- `NULL` attacker → `0`.
- **mode == 4**: prefer structures. If `FindBestTargetStructure` returns non-nil, return `EncodedIndex.structure(index).raw`. Else try `FindBestTargetUnit`; return its encoded index or `0`.
- **mode != 4**: compute both candidates in parallel. Deviators skip structures (`type == DEVIATOR`). When both exist, compare: `if structurePriority >= unitPriority → return structure`. Else unit. If only one is non-nil, return it. If neither, `0`.

Return type is the raw `EncodedIndex` value (`UInt16`).

## 9. `Script_Unit_FindBestTarget` / `Script_Unit_GetTargetPriority`

Both are thin wrappers — trivially built once the above are in place.

- **Slot 0x1C** (`makeFindBestTargetUnit`): `Unit_FindBestTargetEncoded(currentUnit, peek(1), host)`. Returns `0` when no current unit.
- **Slot 0x1D** (`makeGetTargetPriorityUnit`): decodes peek(1); if `.unit` → `GetTargetUnitPriority(currentUnit, target)`; elif `.structure` → `GetTargetStructurePriority(currentUnit, s)`; else → `0`. Tile / invalid → `0`.

## 10. What this does *not* cover

- **Sandworm GetBestTarget** (`Script_Unit_Sandworm_GetBestTarget`, slot 0x36) — separate priority function (`Unit_Sandworm_GetTargetPriority`); deferred until P4 Phase 5.
- **Structure-side FindTargetUnit** (`Script_Structure_FindTargetUnit`, structure slot 0x08) — uses a different pool walk (`PoolFindStruct` in a tighter LOS band). Share the priority helpers but not the dispatcher; deferred.
- **Firing** (`Script_Unit_Fire`, `Unit_CreateBullet`) — still deferred.
- **`Map_IsPositionUnveiled` real impl** — stubbed via the optional host callback; wire the real thing when fog lands.

## 11. Testing

Pure-read functions are easy to pin. The suite covers:

- `House_AreAllied` — invalid, same-house, Fremen↔Atreides, non-player mutual alliance, nil-playerID fallback.
- `GetTargetUnitPriority` — self-zero, unallocated-zero, unseen-zero, allied-zero, priority-flag-off, winger gate (attacker can vs. can't targetAir), off-map returns 0, distance-dividing math pin, clamp at `0x7D00`.
- `GetTargetStructurePriority` — allied-zero, unseen-zero, distance-dividing math pin, clamp at 32000.
- `FindBestTargetUnit` — empty pool → nil, mode-0 picks highest priority ignoring distance, mode-1 skips out-of-range, mode-2 uses origin + double distance, origin-stamp side-effect on mode 2 no-op when already stamped.
- `FindBestTargetStructure` — skips slabs/walls, mode-1 distance gate, `>=` tie-break picks the later-allocated.
- `FindBestTargetEncoded` — mode 4 prefers structure, mode 0 compares both, deviator skips structures, both-nil returns 0.
- Slot 0x1C / 0x1D — round-trip via the VM with an entry that calls `SCRIPT_FUNCTION 0x1C` and one that calls `0x1D`.
