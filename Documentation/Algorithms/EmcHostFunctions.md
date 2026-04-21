# EMC host functions — the `SCRIPT_FUNCTION` dispatch table

Status: Drafted 2026-04-20 (P2 slice 1 — first batch of host-side callbacks).

`Formats.Emc.Program` provides the bytecode; `Scripting.VM` executes it. The third piece is the **host-function table** — the 64 slots that `SCRIPT_FUNCTION n` dispatches into. OpenDUNE carries three such tables (`g_scriptFunctionsStructure`, `g_scriptFunctionsUnit`, `g_scriptFunctionsTeam`), all indexed 0..63, with overlapping implementations for the generic ones (`Script_General_*`). This document covers how we port the generic subset and how callers will wire up the per-category tables as P4 lands.

References:

- OpenDUNE `src/script/general.c` — shared helpers (`Delay`, `DelayRandom`, `RandomRange`, `GetDistanceToTile`, `NoOperation`, `DisplayText`, …).
- OpenDUNE `src/script/script.c` — the three category tables.
- Our types: `Scripting.VM.Function`, `Scripting.Functions`, and the public `push/pop/peek` helpers in `Code/Core/Sources/DuneIICore/Scripting/`.

## 1. Function signature

Host functions in OpenDUNE have the signature `uint16 fn(ScriptEngine *script)`: they read arguments from the stack via `STACK_PEEK` (not pop!), optionally write to `script->delay`, and return a `uint16`. The caller typically follows the `FUNCTION` opcode with a `STACK_REWIND` to discard arguments.

Our Swift equivalent:

```swift
public typealias Function = (inout Engine) -> UInt16
```

The closure can read the stack with `Scripting.peek(engine:position:)`, optionally mutate `engine.delay`, and returns the value the `FUNCTION` opcode writes into `engine.returnValue`. **Functions must not pop their arguments.** The bytecode compiler emits an explicit `STACK_REWIND` after every call, so a popping host function would corrupt the stack.

## 2. New engine field: `delay`

To support `Script_General_Delay`, `Engine` grows a `delay: UInt16` field initialised to `0`:

```swift
public struct Engine: Sendable, Equatable {
    public var pc: Int
    public var delay: UInt16          // new
    public var returnValue: UInt16
    // ... rest unchanged ...
}
```

The field is writable by host functions but **`step()` does not currently consult it**. Delay-based suspension is a tick-scheduler concern that lands with the unit/structure tick in P4. For the moment, `delay` is a simple output field that observers can read after a call.

## 3. Stack helpers made public

`Scripting.popForTest` was an `internal` shim added for the first VM tests. It's now promoted to three public helpers that host functions can use:

```swift
extension Scripting {
    /// Peek at a stack slot without removing it. `position == 1` is the
    /// top of the stack. Halts the engine on underflow. Mirrors OpenDUNE
    /// `Script_Stack_Peek`.
    public static func peek(engine: inout Engine, position: Int) -> UInt16

    /// Pop the top of the stack. Halts on underflow.
    public static func pop(engine: inout Engine) -> UInt16

    /// Push onto the stack. Halts on overflow.
    public static func push(engine: inout Engine, _ value: UInt16)
}
```

Host functions **should prefer `peek`** — it matches OpenDUNE and keeps the stack intact for the compiler-emitted `STACK_REWIND`.

## 4. The first batch: `Scripting.Functions`

```swift
extension Scripting {
    public enum Functions {
        /// `Script_General_NoOperation` — returns 0, no stack effect.
        public static func noOperation(_ engine: inout Engine) -> UInt16

        /// `Script_General_Delay` — `delay = peek(1) / 5`, writes engine.delay.
        public static func delay(_ engine: inout Engine) -> UInt16

        /// Factory: returns a `Function` closure capturing `source` for
        /// `Script_General_RandomRange` — `Tools_RandomLCG_Range(peek(1), peek(2))`.
        /// Mirrors OpenDUNE's use of a single global Borland LCG.
        public static func makeRandomRange(source: RandomSource) -> VM.Function
    }

    /// Reference-typed wrapper around a shared `RNG.BorlandLCG`. The LCG
    /// state is per-game-session; host-function closures close over it.
    public final class RandomSource: @unchecked Sendable {
        public var lcg: RNG.BorlandLCG
        public init(seed: UInt16)
    }
}
```

### `noOperation`

```swift
public static func noOperation(_ engine: inout Engine) -> UInt16 {
    return 0
}
```

Byte-for-byte match. The compiler emits `FUNCTION 0` for a no-op call site, usually followed by a `STACK_REWIND 0` (nothing to clean).

### `delay`

```swift
public static func delay(_ engine: inout Engine) -> UInt16 {
    let ticks = Scripting.peek(engine: &engine, position: 1)
    let d = ticks / 5
    engine.delay = d
    return d
}
```

OpenDUNE divides by 5 because the game ticks run the script every 5 outer ticks. A script asking for a 4-tick delay gets truncated to 0 — that behaviour is observable in real scripts and must be preserved.

### `randomRange`

```swift
public static func makeRandomRange(source: RandomSource) -> VM.Function {
    return { engine in
        let lo = Scripting.peek(engine: &engine, position: 1)
        let hi = Scripting.peek(engine: &engine, position: 2)
        let v = source.lcg.range(lo, hi)
        return v
    }
}
```

`source.lcg.range(lo, hi)` is our existing `RNG.BorlandLCG.range(_:_:)` — already pinned-baselined against `Tools_RandomLCG_Range`. The factory pattern (rather than a bare static function) is how we inject shared state: every closure created from `makeRandomRange(source:)` draws from the same LCG, so two scripts running in the same session see the canonical Dune II "one shared stream" behaviour.

## 5. Wiring a pool of functions

A category table is a 64-slot `[VM.Function?]` array. For our first batch, a common "general" table looks like:

```swift
let source = Scripting.RandomSource(seed: scenarioSeed)
var functions = [Scripting.VM.Function?](repeating: nil, count: 64)
functions[0] = Scripting.Functions.delay              // 0x00 — Script_General_Delay
functions[1] = Scripting.Functions.noOperation        // 0x01 — Script_General_NoOperation
// ... per-category overrides for 0x02 onward ...
let vm = Scripting.VM(program: program, functions: functions)
```

The index-to-function mapping is **category-specific** — `g_scriptFunctionsStructure[0]` is `Script_General_Delay`, but `g_scriptFunctionsUnit[0]` is `Script_Unit_GetInfo`. Each call site (structure AI, unit AI, team AI) will assemble its own 64-slot table. This slice ships only the generic entries that overlap all three categories.

## 6. Testing

`Core/Tests/DuneIICoreTests/EmcFunctionsTests.swift`:

1. **Reset initialises `delay == 0`.** Confirms the new field.
2. **NoOperation leaves the stack untouched and sets `returnValue` to 0.** Load a `PUSH 42; FUNCTION 1` program where slot 1 is `noOperation`; assert `stack[14] == 42` and `returnValue == 0`.
3. **Delay writes `delay = peek(1) / 5`.** `PUSH 25; FUNCTION 0` → `engine.delay == 5`, `returnValue == 5`. Stack is not popped.
4. **Delay truncates sub-5-tick requests to 0.** `PUSH 4; FUNCTION 0` → `delay == 0`.
5. **RandomRange returns values in `[lo, hi]`.** `PUSH 10; PUSH 20; FUNCTION 2` with a `RandomSource(seed: 1)`; step once and assert `returnValue` is in `[10, 20]`.
6. **RandomRange uses shared state.** Create one `RandomSource`, wire two separate VMs that both call `FUNCTION 2` once — the second VM's draw should equal the one-step-further value of the same LCG, not the first draw.
7. **Existing VM tests continue to pass** after `popForTest` is promoted to the public `pop` helper.

## 7. Second batch — host-context-aware functions

The first batch covered the zero-dependency generics. The second adds five
functions that need world state: four read it, one writes to an observable
event log. They all live on `Scripting.Functions` as `makeXxx(host:)`
factories that close over a shared `Scripting.Host`.

### 7.1 `Scripting.EncodedIndex`

`Tools_Index_*` in OpenDUNE packs `{type, index}` into a single `uint16`
(top two bits pick the `IndexType`; lower 14 bits carry the index — with a
different encoding for `IT_TILE`). Our port is a pure value type:

```swift
public struct EncodedIndex: Sendable, Equatable {
    public let raw: UInt16
    public enum Kind: Sendable { case none, tile, unit, structure }
    public var kind: Kind { /* raw & 0xC000 → switch */ }
    /// Pool index (`0…0x3FFF`) for unit/structure; packed-tile for tile.
    public var decoded: UInt16 { /* Tile_PackXY for tile case; raw & 0x3FFF otherwise */ }
    public static func unit(_ index: UInt16) -> EncodedIndex   // index | 0x4000
    public static func structure(_ index: UInt16) -> EncodedIndex // index | 0x8000
}
```

Validity (`Tools_Index_IsValid`) depends on live pool state (`used`,
`allocated`), so it lives on `Host`, not on `EncodedIndex` itself.

### 7.2 `Scripting.Host`

Reference type — host callbacks need to mutate it (e.g. append to the text
log) while the engine value type stays pure.

```swift
public final class Host: @unchecked Sendable {
    public var units: Simulation.UnitPool
    public var structures: Simulation.StructurePool
    /// `g_scriptCurrentObject` analogue. `nil` when no object is active.
    public var currentObject: ObjectRef?
    /// `scriptInfo->text` analogue. Pass the EMC program's text table here.
    public var texts: [String]
    /// DisplayText call sink. Tests assert on this; a live UI would route
    /// the text to the message queue instead.
    public var textLog: [DisplayedText]

    public enum ObjectRef: Sendable, Equatable {
        case unit(poolIndex: Int)
        case structure(poolIndex: Int)
    }
    public struct DisplayedText: Sendable, Equatable {
        public let text: String
        public let arg1, arg2, arg3: UInt16
    }
}
```

### 7.3 `UnitSlot` gains `orientationCurrent`

`GetOrientation` reads `u->orientation[0].current` (`int8`). We add a
minimal field to `Simulation.UnitSlot`:

```swift
public var orientationCurrent: Int8 = 0
```

`Simulation.WorldSnapshot` populates it from `save.orientation[0].current`
so loaded units report the correct turret heading. This is the first
"gameplay state" field on `UnitSlot` beyond the bare-minimum allocator
fields — per CLAUDE.md we only add fields when a system needs them.

### 7.4 The five functions

```swift
public enum Functions {
    /// `Script_General_DisplayText` — peek(1)=textIndex, peek(2-4)=args.
    /// Appends a `DisplayedText` to host.textLog. Returns 0.
    public static func makeDisplayText(host: Host) -> VM.Function

    /// `Script_General_UnitCount` — counts units matching
    /// (host.currentObject.houseID, peek(1)=type). Returns 0 if no
    /// currentObject is set.
    public static func makeUnitCount(host: Host) -> VM.Function

    /// `Script_General_GetOrientation` — decodes peek(1) as an encoded
    /// unit index; returns `orientationCurrent` of the pool slot, or
    /// `128` when the reference is invalid / not a unit / slot freed.
    public static func makeGetOrientation(host: Host) -> VM.Function

    /// `Script_General_IsFriendly` — returns `1` if the referenced
    /// object's houseID matches currentObject's houseID, `-1` (as
    /// `UInt16(bitPattern:)`) if enemy, `0` if the reference is invalid.
    public static func makeIsFriendly(host: Host) -> VM.Function

    /// `Script_General_IsEnemy` — `1` if enemy houseID, `0` otherwise.
    /// Invalid references also return `0` (matches OpenDUNE).
    public static func makeIsEnemy(host: Host) -> VM.Function
}
```

### 7.5 Testing strategy

For each function, pin a pre-arranged `Host` state (pool with specific
slots allocated, `currentObject` set, `texts` array supplied) plus a
pinned input stack, then step a trivial `PUSH … FUNCTION n` program and
assert both the return value and any host-side effect.

`IsFriendly` / `IsEnemy` tests sweep four cases each: same-house,
different-house, invalid-index (returns 0), index-of-type-tile (returns 0
— `IsEnemy` only recognises `IT_UNIT` / `IT_STRUCTURE`).

## 8. Third batch — unit-specific generics

Batch 2 plumbed `Scripting.Host` + `EncodedIndex` + five `Script_General_*` that need world state. Batch 3 is the first ingress into the per-category tables: three entries drawn from OpenDUNE's `g_scriptFunctionsUnit` (`src/script/script.c:64`), all reading or mutating the *current unit*. They live on `Scripting.Functions` as `makeXxxUnit(host:)` factories that close over the shared `Host`.

### 8.1 New `Simulation.UnitSlot` fields

`GetInfo` / `SetAction` / `GetAmount` together touch five previously-absent slot fields. We add them in one pass, matching OpenDUNE's `Unit` layout, and route them through `WorldSnapshot` from the matching save fields:

```swift
public var actionID: UInt8          // u->actionID — current action enum
public var amount: UInt8            // u->amount — cargo/payload counter
public var targetAttack: UInt16     // u->targetAttack — encoded target
public var targetMove: UInt16       // u->targetMove — encoded destination
public var originEncoded: UInt16    // u->originEncoded — home refinery etc.
```

Save-source plumbing (`Simulation.WorldSnapshot.init`): take `actionID` / `amount` / `targetAttack` / `targetMove` / `originEncoded` from the corresponding `Formats.Save.Units.Slot` fields verbatim.

### 8.2 `Script_Unit_GetInfo` (unit slot 0x00)

`Unit_GetInfo` in OpenDUNE is a 20-way switch on `STACK_PEEK(1)`. We implement the subcases whose state is already live on `UnitSlot` + `ObjectHeader`. Subcases that require `g_table_unitInfo` (0x00 hitpoints ratio, 0x02 fireDistance, 0x0A/0x11 orientation deltas, 0x0D explodeOnDeath, 0x12 movementType, 0x10 turret-vs-body split) or `g_playerHouseID` (0x13 seenByHouses bit) are deferred — they return `0`, matching OpenDUNE's `default` branch behaviour. The port will add them when a scenario actually needs them.

Supported subcases (current unit `u` = `host.currentObject.unit(poolIndex:)` or `nil`):

| peek(1) | Return | Source |
|---|---|---|
| 0x01 | `targetMove` if valid, else `0` | `u.targetMove`, validity via Host |
| 0x03 | `index` | `u.index` |
| 0x04 | `orientationCurrent` | `u.orientationCurrent` (sign-extended) |
| 0x05 | `targetAttack` | `u.targetAttack` |
| 0x06 | `originEncoded` | `u.originEncoded` (no auto-`FindClosestRefinery`) |
| 0x07 | `type` | `u.type` |
| 0x08 | `Tools_Index_Encode(u.index, IT_UNIT)` | `EncodedIndex.unit(index).raw` |
| 0x0E | `houseID` | `u.houseID` |

Other subcases, including `default`, return `0`. Called with no current unit, also returns `0`.

### 8.3 `Script_Unit_SetAction` (unit slot 0x01)

`Unit_SetAction` in OpenDUNE gates on a player-side early-out (`houseID == g_playerHouseID && action == ACTION_HARVEST && nextActionID != ACTION_INVALID`), then calls `Unit_SetAction(u, action)` which in turn sets `u->actionID`. We do the minimal port:

- Read `action = peek(1) & 0xFF`.
- Write `action` to `currentObject.unit.actionID` (nothing if no current unit).
- Always return `0`. The player-harvest early-out and the richer side-effects (`Unit_UpdateMap`, ordering changes) are intentionally deferred until the action system lands.

This is the first host function that mutates pool state, so the test not only checks the return value but also asserts the slot's `actionID` was written.

### 8.4 `Script_Unit_GetAmount` (unit slot 0x20)

`Unit_GetAmount` in OpenDUNE returns `u->amount` if `linkedID == 0xFF`, otherwise `Unit_Get_ByIndex(linkedID)->amount`. Direct port:

- If `currentObject` is nil, return `0`.
- If `u.linkedID == 0xFF`, return `u.amount`.
- Otherwise look up the linked unit via `host.units.slots[u.linkedID]`; if used + allocated, return its `amount`; else fall back to `u.amount` (OpenDUNE would segfault — we treat the dangling linkedID as "use own amount" because the save is internally consistent in vanilla games).

### 8.5 Testing

One test per function, minimum:

1. `GetInfo` on a pinned unit at slot 5, with `type=3`, `houseID=2`, `orientationCurrent=64`, `targetAttack=0x4010`, `originEncoded=0x8008`, `targetMove=0` — sweep peek values `{0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0E}` and assert the expected return for each. One extra assertion for an unsupported subcase (`0x00`) returning `0`.
2. `GetInfo` with no `currentObject` returns `0`.
3. `SetAction` writes `actionID = peek(1) & 0xFF` to the current unit and returns `0`.
4. `SetAction` with no `currentObject` is a no-op (returns `0`, nothing is mutated).
5. `GetAmount` on a non-linked unit returns `u.amount`.
6. `GetAmount` on a linked unit returns the linked unit's `amount`.
7. `WorldSnapshot` round-trip: load `_SAVE001.DAT` and assert the new fields (`actionID` / `amount` / `targetAttack` / `targetMove` / `originEncoded`) on at least one allocated unit equal the corresponding save-record values.

## 9. Fourth batch — structure-specific generics

Batch 3 covered the smallest `Script_Unit_*` entries. Batch 4 opens the per-category table for structures — `g_scriptFunctionsStructure` in `src/script/script.c:33`. We start with the two trivially-sized state accessors (`GetState` slot 0x0D, `SetState` slot 0x04) because they have no downstream dependency on unreachable tables (no `g_table_structureInfo`, no `Structure_UpdateMap` side-effects we care about at this layer).

### 9.1 New `Simulation.StructureSlot` fields

Both accessors touch `s->state` (signed 16-bit). `SetState` has a DETECT branch that also reads `s->countDown`. We add both fields in one pass and plumb them through `WorldSnapshot`:

```swift
public var state: Int16          // s->state — signed; -2/-1/0/1/2 enum range
public var countDown: UInt16     // s->countDown — production/unload countdown
```

Save-source plumbing in `Simulation.WorldSnapshot.init`: copy `state` and `countDown` verbatim from the matching `Formats.Save.Structures.Slot` fields.

### 9.2 `Script_Structure_GetState` (structure slot 0x0D)

One-liner in OpenDUNE: `return s->state`. The signed Int16 is reinterpret-cast to UInt16 on return (so `state == -1` becomes `0xFFFF`). Our port:

- Resolve current structure via `host.currentObject = .structure(poolIndex:)`; any of the allocated slots [0, 78] OR a live reserved slot [79, 81] counts.
- Return `UInt16(bitPattern: slot.state)`.
- No current structure → `0` (matches OpenDUNE's `default`-style null-safety: we refuse to deref a missing structure).

### 9.3 `Script_Structure_SetState` (structure slot 0x04)

OpenDUNE:

```c
state = STACK_PEEK(1);
if (state == STRUCTURE_STATE_DETECT) {               // -2
    if (s->o.linkedID == 0xFF)          state = IDLE;
    else if (s->countDown == 0)         state = READY;
    else                                state = BUSY;
}
Structure_SetState(s, state);      // writes s->state, updates map
return 0;
```

Our port:

- Read `requested = Int16(bitPattern: peek(1))`.
- If `requested == -2` (DETECT), resolve:
  - `linkedID == 0xFF` → `0` (IDLE)
  - `countDown == 0`   → `2` (READY)
  - else               → `1` (BUSY)
- Write `slot.state = resolved` (via `host.structures[poolIndex] = slot`).
- Return `0`. The map-update side-effect is deferred (renderer / overlay concern).

No-current-structure path is also a no-op returning `0`.

### 9.4 Testing

One test per branch:

1. `GetState` on a pinned structure with `state = -1` returns `0xFFFF`.
2. `GetState` with no `currentObject` returns `0`.
3. `SetState` writes an explicit non-DETECT value (`peek = 2`, resolves to `state == 2`).
4. `SetState` DETECT with `linkedID == 0xFF` resolves to IDLE (`state == 0`).
5. `SetState` DETECT with `linkedID != 0xFF` and `countDown == 0` resolves to READY (`state == 2`).
6. `SetState` DETECT with `linkedID != 0xFF` and `countDown != 0` resolves to BUSY (`state == 1`).
7. `SetState` always returns `0`.
8. `WorldSnapshot` round-trip on `_SAVE001.DAT` asserts the two new fields equal the save record for every allocated structure.

## 10. Fifth batch — more generics, no new state

Batch 4 opened the structure table with state accessors. Batch 5 picks up five further `Script_General_*` entries that need no new pool fields — every read hits state already on `Host` / `UnitSlot` / `StructureSlot` / `RandomSource`. These are used across both unit and structure dispatch tables (some repeat in the team table too), so landing them once drains a large fraction of unreachable slots.

### 10.1 `Script_General_DelayRandom` (unit slot 0x3C)

OpenDUNE:

```c
delay = Tools_Random_256() * STACK_PEEK(1) / 256;
delay /= 5;
script->delay = delay;
return delay;
```

`Tools_Random_256()` is the 8-bit PRNG we ported in `Core.RNG.ToolsRandom256`. The current `RandomSource` carries a `BorlandLCG`; we extend it with a `ToolsRandom256` stream so `DelayRandom` can share the closed-over source. Add a `nextUInt8()` accessor to `RandomSource`. Factory shape mirrors `makeRandomRange`:

```swift
public static func makeDelayRandom(source: RandomSource) -> VM.Function
```

Returns the computed delay; writes `engine.delay`.

### 10.2 `Script_General_GetIndexType` (unit slot 0x2D)

Pure `EncodedIndex` operation gated by live `Tools_Index_IsValid`. Return values mirror `IndexType` from OpenDUNE:

- `IT_NONE = 0`
- `IT_TILE = 1`
- `IT_UNIT = 2`
- `IT_STRUCTURE = 3`

Invalid encoded value → `0xFFFF` (the OpenDUNE `Script_General_GetIndexType` escape). Since validity depends on live pool state, this is a `makeGetIndexType(host:)` factory.

### 10.3 `Script_General_DecodeIndex` (unit slot 0x2E)

Same factory shape. Returns `EncodedIndex.decoded` (which yields pool-index for unit/structure and `Tile_PackXY` for tile). Invalid → `0xFFFF`.

### 10.4 `Script_General_GetLinkedUnitType` (unit slot 0x2C)

Reads `currentObject.linkedID` (either a unit or structure may be current — both carry `linkedID`). If `0xFF` → `0xFFFF`; otherwise looks up the linked slot's `type` in `host.units`. Non-live linked slot also returns `0xFFFF` (defensive — OpenDUNE would segfault on a freed linkedID in vanilla-safe scenarios).

### 10.5 `Script_General_FindIdle` (unit slot 0x18)

Two-mode function dispatching on the encoded index's kind:

- `IT_UNIT` or `IT_TILE` → always return `0`.
- `IT_STRUCTURE` → look up the structure; if `houseID == currentHouseID` and `state == 0` (IDLE), return `1`, else `0`.
- `IT_NONE` / raw integer (the "type" mode) → iterate `host.structures` via `PoolQuery(houseID: currentHouseID, type: UInt8(truncatingIfNeeded: peek))`; return the first slot whose `state == 0` as `EncodedIndex.structure(index).raw`; else `0`.

The function needs the structure `state` field — landed in batch 4.

### 10.6 Testing

One test per function, plus one edge case per function:

1. `DelayRandom` returns `(toolsRandom256 * peek) / 256 / 5` and writes `engine.delay`. Pin with a seeded source.
2. `DelayRandom` shares state with `RandomRange` (both drawn from the same `RandomSource`).
3. `GetIndexType` returns the OpenDUNE `IT_*` constant for each kind (none/tile/unit/structure) — valid cases.
4. `GetIndexType` returns `0xFFFF` for an encoded unit whose slot is freed.
5. `DecodeIndex` returns pool-index for unit/structure and `Tile_PackXY` for tile; `0xFFFF` invalid.
6. `GetLinkedUnitType` returns the linked unit's type when `linkedID != 0xFF`; `0xFFFF` otherwise.
7. `FindIdle` in structure-index mode: same-house + IDLE → `1`; same-house + non-IDLE → `0`; different house → `0`.
8. `FindIdle` in structure-type mode: returns the first IDLE structure's encoded index; returns `0` when none match.

## 11. Related insights

- Existing `format-emc-variable-instruction-width.md` — how a `FUNCTION` opcode is encoded.
- Existing `scripting-emc-saved-location-plus-one.md` — subroutine calling convention; host functions live on the same stack but never push the `pc + 1` marker.
- Future `scripting-host-fn-peek-not-pop.md` — once we have a regression to point at, capture the "host functions must peek" rule that's load-bearing for stack parity.
