# Entity pools — Unit / Structure / House

Status: Drafted 2026-04-20 (P2 slice 1 — gate for any P4 simulation work).

Every live entity in Dune II — units, structures, houses, teams — lives inside a fixed-size pool with a stable slot index. Slot indices are persistent identifiers used by save files, by inter-entity links (`linkedID`, `starportLinkedID`), and by AI scripts. The pool layouts and allocation rules are byte-for-byte from OpenDUNE; getting them wrong means save-file divergence and inter-entity reference corruption.

References:

- OpenDUNE `src/pool/unit.{c,h}`, `src/pool/structure.{c,h}`, `src/pool/house.{c,h}`.
- Our types: `Simulation.*` in `Code/Core/Sources/DuneIICore/Simulation/`.

## 1. Capacities and reserved slots

| Pool | Capacity | Notes |
|------|----------|-------|
| `UnitPool` | 102 | `UNIT_INDEX_MAX = 102`. Auto-allocation searches a per-type sub-range that the unit table will define in P4. |
| `StructurePool` | 82 hard / 79 soft | Indices `0…78` are normal structures (refineries, factories, etc.); indices `79`, `80`, `81` are reserved aggregates for **walls**, **2×2 slabs**, and **1×1 slabs** respectively. The reserved slots never appear in the find-array and are re-initialised on every allocation rather than checked for "already used". |
| `HousePool` | 6 | One slot per playable / observable house. Always allocated at an explicit index. |

Sentinel: `0xFFFF` is the universal "invalid index" value across all three pools. Linked-ID fields (`linkedID`, `starportLinkedID`) use `0xFF` (UInt8) or `0xFFFF` (UInt16) to mean "not linked".

## 2. Slot data

Each pool owns a `[Slot]` array of fixed length. Slots are value types:

```swift
public struct UnitSlot: Sendable, Equatable {
    public var isUsed: Bool
    public var isAllocated: Bool
    public var index: UInt16          // matches array position when used
    public var type: UInt8
    public var houseID: UInt8
    public var linkedID: UInt8        // 0xFF when none
}

public struct StructureSlot: Sendable, Equatable {
    public var isUsed: Bool
    public var isAllocated: Bool
    public var index: UInt16
    public var type: UInt8
    public var houseID: UInt8         // unused for the three reserved aggregate slots
    public var linkedID: UInt8
}

public struct HouseSlot: Sendable, Equatable {
    public var isUsed: Bool
    public var index: UInt8
    public var starportLinkedID: UInt16  // 0xFFFF when none
}
```

These structs are deliberately minimal. The full Unit / Structure / House records (movement state, build queues, voice-line indices, etc.) will land alongside the systems that need them in P4. The pool API is stable; the slot type can grow without breaking call sites that only allocate / free / index.

## 3. Find-array (iteration cache)

OpenDUNE keeps a parallel `g_*FindArray[]` of pointers to currently-used slots in **insertion order**. Iteration via `Unit_Find` / `Structure_Find` / `House_Find` walks this array, skipping entries that don't match the filter (house, type). This is purely a performance cache — `Unit_Recount` rebuilds it from scratch by scanning the slot array — but the **insertion order is observable** because save-file ordering and tick-update ordering both follow it.

Our Swift port mirrors this with:

```swift
public private(set) var findArray: [Int]   // slot indices in allocation order
```

`allocate` appends to `findArray`. `free` finds the entry, decrements the count, and `memmove`s the trailing entries down — preserving insertion order, not swap-remove.

The three reserved StructurePool slots (`indexWall`, `indexSlab2x2`, `indexSlab1x1`) **never appear in `findArray`**; OpenDUNE's `Structure_Find` walks `findArray` then appends the three reserved indices as a tail trio.

## 4. Allocation API

```swift
public struct UnitPool: Sendable, Equatable {
    public static let capacity = 102
    public static let invalidIndex: UInt16 = 0xFFFF

    public private(set) var slots: [UnitSlot]
    public private(set) var findArray: [Int]

    public init()
    public subscript(index: Int) -> UnitSlot { get set }

    /// Allocate at a specific slot. Returns nil if the slot is already in use.
    @discardableResult
    public mutating func allocate(at index: Int, type: UInt8, houseID: UInt8) -> Int?

    /// Linear-scan `[range]` for the first unused slot. Returns nil if the
    /// range is full. Mirrors OpenDUNE's per-type `[indexStart..indexEnd]`
    /// auto-allocation; the type→range map will land in P4.
    @discardableResult
    public mutating func allocate(in range: ClosedRange<Int>, type: UInt8, houseID: UInt8) -> Int?

    public mutating func free(at index: Int)
}
```

`StructurePool` adds a third entry point for the reserved aggregates:

```swift
/// Re-initialises the reserved slot at `index` (must be one of `indexWall`,
/// `indexSlab2x2`, `indexSlab1x1`). Always succeeds; the previous content
/// is discarded. Does NOT touch `findArray`.
@discardableResult
public mutating func allocateReserved(at index: Int, type: UInt8) -> Int
```

`HousePool` only exposes the explicit-index path — houses are never auto-allocated.

## 5. The House_Free divergence

OpenDUNE's `House_Free` removes the house from the find-array but **does not clear `flags.used`**. As a result, `House_Allocate(index)` of the same slot subsequently fails — but iteration via `House_Find` no longer returns it. This looks like a bug; in practice OpenDUNE never frees a house during play, so the bug is unobservable.

We mirror this verbatim: `HousePool.free(at:)` removes from `findArray` and leaves `slots[i].isUsed == true`. Anyone who needs to reset a house slot must mutate `slots[i]` directly. The behaviour is captured in `Insights/simulation-house-free-leaves-used.md`.

## 6. Filtered iteration — `PoolQuery`

OpenDUNE's `Unit_Find` / `Structure_Find` / `House_Find` share a common filter-and-resume pattern driven by a `PoolFindStruct { houseID, type, index }`. Callers set `index = 0xFFFF` on the first call; the function increments it, walks the find-array, skips entries that fail the filter, and writes the last-visited position back. A `NULL` return means "no more matches."

Our Swift port wraps that pattern in a value type:

```swift
public struct PoolQuery: Sendable, Equatable {
    public var houseID: UInt8?    // nil == match any house
    public var type: UInt8?       // nil == match any type
    internal var position: Int    // opaque cursor; -1 before the first call

    public init(houseID: UInt8? = nil, type: UInt8? = nil)
}

extension UnitPool {
    /// Advance `query` to the next matching slot. Returns nil when the
    /// iteration is exhausted. Mirrors OpenDUNE's `Unit_Find`.
    public func next(_ query: inout PoolQuery) -> UnitSlot?
}

extension StructurePool {
    /// Walk `findArray` first; after the last entry, yield the three
    /// reserved aggregates (`indexWall`, `indexSlab2x2`, `indexSlab1x1`)
    /// in that order, but only if the reserved slot's `isUsed` flag is
    /// set. Mirrors OpenDUNE's `Structure_Find` tail-trio walk.
    public func next(_ query: inout PoolQuery) -> StructureSlot?
}
```

Iteration order is **insertion order** (the order slots were allocated), not natural-slot order. Freed slots disappear from the walk even if their data is still in the backing array (matches the find-array semantics from §3).

The `nil` filter value means "match anything" — in OpenDUNE this is spelled `HOUSE_INVALID` (0xFF) and `UNIT_INDEX_INVALID` (0xFFFF). Our `UInt8?` / `UInt8?` makes the "any" sentinel explicit at the type level.

### Usage

```swift
var query = PoolQuery(houseID: 1, type: nil)
while let slot = unitPool.next(&query) {
    // process all house-1 units in insertion order
}
```

Callers can `break` out early and resume later by keeping the same `query` value around; the opaque `position` persists.

### Quirks we port verbatim

- **HousePool has no `next(_:)`.** OpenDUNE's `House_Find` has no real filters — it just walks the find-array and returns non-null entries. With our current minimal `HouseSlot`, a plain `for index in housePool.findArray` loop does the job. We'll add `HousePool.next(_:)` when a houseID-equivalent filter becomes useful.
- **Out-of-range start.** OpenDUNE's `if (find->index >= g_unitFindCount && find->index != 0xFFFF) return NULL;` is a safety net for callers who continue iterating after exhaustion. We preserve this: `next(_:)` on an exhausted query returns `nil` without advancing.
- **Reserved structure slots.** See §4 — they never appear in `findArray` but `Structure_Find` still visits them. `StructurePool.next(_:)` replicates the three-slot tail walk.

### Fields we will add later

When `UnitSlot` / `StructureSlot` grow an `isNotOnMap` flag, `next(_:)` will gain the same skip-unless-`g_validateStrictIfZero` guard OpenDUNE uses. For this slice we only filter on `houseID` and `type`.

## 7. Testing

`Core/Tests/DuneIICoreTests/PoolTests.swift`:

1. **Empty pool.** All three pools initialise with all-zero slots, empty `findArray`.
2. **UnitPool.allocate(at:) round-trip.** Allocate at slot 5, assert `slots[5].isUsed`, `slots[5].index == 5`, `findArray == [5]`.
3. **UnitPool.allocate(at:) twice on same slot returns nil.** Second call leaves state unchanged.
4. **UnitPool.allocate(in:) walks range linearly.** Pre-fill slot 0; allocate in `0...3` returns 1.
5. **UnitPool.allocate(in:) returns nil when range exhausted.** Fill `0...2`; allocate in `0...2` returns nil.
6. **UnitPool.free preserves find-array order.** Allocate slots 2, 5, 8 (find-array `[2, 5, 8]`); free slot 5; expect `findArray == [2, 8]` and `slots[5].isUsed == false`.
7. **UnitPool.free of unused slot is a no-op.** No crash, no find-array mutation.
8. **StructurePool.allocateReserved at index 79 always succeeds.** Two calls back-to-back both return 79; `findArray` stays empty; `slots[79].isUsed == true`.
9. **StructurePool.allocate normal range never returns 79/80/81.** `allocate(in: 0...81, ...)` only walks `0...78`.
10. **HousePool.allocate(at: 3) twice returns nil the second time.**
11. **HousePool.free leaves `isUsed == true` (the documented OpenDUNE quirk).** Allocate house 2; free it; assert `slots[2].isUsed == true` and `findArray.isEmpty`.
12. **Determinism / `Sendable` round-trip.** Re-running the same allocation sequence on a fresh pool produces an `Equatable`-equal pool.

All synthetic; no install required.

## 8. Related insights

- Future `simulation-house-free-leaves-used.md` — captures the `House_Free` quirk above.
