# `ODUN` exists to carry fields `UNIT` truncated on disk

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Formats/Save/SaveUnits.swift`
- **Category**: format
- **Applies to**: `Formats.Save.Units`, any future ODUN decoder / round-tripper

## The fact

OpenDUNE's "new unit" chunk `ODUN` is not a collection of fresh OpenDUNE-era fields. It exists because several `Unit` fields were *deliberately narrowed* in the on-disk `UNIT` record and need restoring to full width. The two currently observed cases are:

- `Unit.fireDelay` is `u16` in memory but `SLD_ENTRY2(Unit, SLDT_UINT8, fireDelay, SLDT_UINT16)` writes only the low byte to `UNIT`. `ODUN` carries the full `u16` and patches it back after `UNIT` has loaded.
- `Unit.deviated` (a tick counter) is present in `UNIT`, but it *implies* "Ordos did the deviation" — the original 1.07 engine hard-coded that. `ODUN` adds a `deviatedHouse` byte so other houses can deviate units. `Unit_Load` defensively sets `deviatedHouse = HOUSE_ORDOS` whenever `deviated != 0` and `ODUN` is absent.

## Why it matters

A naïve "ODUN = optional extra state you can ignore" mental model is wrong. When `ODUN` is present, it *overwrites* the low byte of `fireDelay` with the correct high + low bytes; a reader that merges `ODUN` into `UNIT` must patch, not append. When `ODUN` is absent (vanilla 1.07), callers must *not* assume the high byte of `fireDelay` is zero — they must treat `fireDelay` as already having an authoritative low-byte value in `UNIT`, and they must assume deviated units are Ordos-owned. Getting either rule wrong silently corrupts unit state after load.

Because vanilla 1.07 never writes `ODUN`, our test fixtures don't exercise the merge path against real data. The merge semantics are synthetic-only until we add an OpenDUNE-produced save to the corpus (deferred — see CurrentState risks).

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Formats/Save/SaveUnits.swift` — `Slot.fireDelay: UInt8` (narrowed) + doc comment pointing at `ODUN` for the high byte.
- `Code/Core/Tests/DuneIICoreTests/SaveUnitsTests.swift:save001HasNoOdun` — pins the absence-of-ODUN invariant in vanilla saves so a future refactor can't silently start requiring it.

## Where it lives in the reference

- OpenDUNE `src/saveload/unit.c:28` — the `SLD_ENTRY2(Unit, SLDT_UINT8, fireDelay, SLDT_UINT16)` narrowing.
- OpenDUNE `src/saveload/unit.c:91–93` — `Unit_Load` sets `deviatedHouse = HOUSE_ORDOS` when `ODUN` was absent.
- OpenDUNE `src/saveload/unit.c:57–63` — `s_saveUnitNew` is the `ODUN` record layout: `u16 fireDelay`, `u8 deviatedHouse`, `u8 pad`, `u16[6] pad`.
