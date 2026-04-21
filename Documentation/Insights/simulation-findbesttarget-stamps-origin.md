# `Unit_FindBestTargetUnit` mutates the attacker

**Category:** `simulation`

## The fact

`Unit_FindBestTargetUnit` (`src/unit.c:923`) is called from a function named `FindBestTargetEncoded` and returns a candidate — by every convention, that's a "read" operation. In practice, it mutates the attacker:

```c
if (u->originEncoded == 0) {
    u->originEncoded = Tools_Index_Encode(Tile_PackTile(position), IT_TILE);
} else {
    position = Tools_Index_GetTile(u->originEncoded);
}
```

First call: stamps `originEncoded` with the attacker's current tile. Subsequent calls: use the stamped origin as the "home position" for mode-2 distance checks. There is no code path in the stock binary that ever *clears* `originEncoded` other than `Unit_CreateBullet` / `Unit_Create` (slot allocation) and carryall-returns (`Unit_Deviate`). Once stamped, it persists for the rest of the unit's life.

## Why it matters

The stamp is load-bearing for harvester return-to-refinery and carryall return-to-origin: the "home" point is captured once, at the first combat evaluation, and then the unit remembers it across the entire engagement / retreat cycle. If we "optimise" by making `FindBestTargetUnit` a pure function, carryalls will fly back to wherever they happen to be when the evaluation runs, not where they spawned.

## How to apply

1. `findBestTargetUnit` on our side **must** write through `host.units[attackerIndex]` on first call. Tests for this live in `TargetAcquisitionTests.swift — findBestTargetUnit stamps originEncoded on first call`.
2. The dispatcher `FindBestTargetEncoded` calls `FindBestTargetUnit` *first*, then `FindBestTargetStructure` — the structure scanner relies on `originEncoded` already being stamped (it reads `Tools_Index_GetTile(originEncoded)` with no fallback-to-position).
3. When we add a "re-evaluate origin" path (e.g. MCV deploy), we need to explicitly clear `originEncoded = 0` first. A subsequent call will re-stamp.

## Also non-obvious: target priority uses the *target's* fireDistance

Inside `Unit_GetTargetUnitPriority`, when the attacker is off-map:

```c
if (!Map_IsValidPosition(Tile_PackTile(unit->o.position))) {
    if (targetInfo->fireDistance >= distance) return 0;
}
```

The cap compares against `targetInfo->fireDistance`, not `unitInfo->fireDistance`. This means an off-map **non-combatant** attacker (fireDistance = 0) can still nominate long-range targets, while an off-map **long-range** attacker has its targeting narrowed by whatever the target's range is. Looks like a bug; it's the shipped behaviour, and changing it alters mission 8+ sandworm priorities. We preserve it.

## Related

- `Documentation/Algorithms/TargetAcquisition.md` §4 — the full port.
- `Code/Core/Sources/DuneIICore/Simulation/TargetAcquisition.swift` — `findBestTargetUnit` + `targetUnitPriority`.
- `Code/Core/Tests/DuneIICoreTests/TargetAcquisitionTests.swift` — `findBestTargetUnit stamps originEncoded on first call` pins the behaviour.
