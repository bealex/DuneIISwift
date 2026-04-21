# EMC virtual machine — stack-based executor for compiled scripts

Status: Drafted 2026-04-20 (P2 slice 1 — first simulation-facing primitive for P4).

`Formats.Emc.Program` already byte-decodes a compiled EMC file into an instruction stream (see `Documentation/Formats/EMC.md`). The VM described here *runs* that stream — one opcode per `step()` call — so scenario AI, structures, and units can each drive their own engine instance with persistent stack/frame/local state.

References:

- OpenDUNE `src/script/script.h` — the `ScriptEngine` / `ScriptInfo` layout and `SCRIPT_*` opcode enum.
- OpenDUNE `src/script/script.c` — `Script_Run`, `Script_Stack_Push/Pop/Peek`, `Script_Reset`, `Script_Load`, `Script_LoadAsSubroutine`.
- Our types: `Formats.Emc.Program` (already shipped) and the new `Scripting.*` namespace in `Code/Core/Sources/DuneIICore/Scripting/`.

## 1. Engine state

```swift
public enum Scripting {
    public struct Engine: Sendable, Equatable {
        public var pc: Int                  // word index into Program.code — `script - start`
        public var returnValue: UInt16
        public var framePointer: UInt8      // initial 17 (no frame)
        public var stackPointer: UInt8      // initial 15 (stack empty); grows downward
        public var variables: [UInt16]      // 5 entries, zero-initialised
        public var stack: [UInt16]          // 15 entries, zero-initialised
        public var isSubroutine: Bool
        public var halted: Bool             // true when engine has fatally errored
    }
}
```

The stack grows **downward**: `push` does `stack[--SP] = v` and `pop` does `stack[SP++]`. `SP == 15` means "empty"; `SP == 0` means "full". Peek-at-position is `stack[SP + position - 1]` with `position >= 1`.

`framePointer = 17` is the sentinel "no active frame" value. It's deliberately >15 so any local- or parameter-access through it trips the range check and halts the engine. Real frames are set up by `PUSH_RETURN_OR_LOCATION(1)` (see §3).

## 2. Program + function table — `Scripting.VM`

```swift
public struct VM {
    public typealias Function = @Sendable (inout Engine, inout VM) -> UInt16
    public let program: Formats.Emc.Program
    public var functions: [Function?]       // 64 slots, indexed by SCRIPT_FUNCTION parameter

    public func entryPoint(typeID: Int) -> Int?

    /// Resets to a clean engine and sets the PC to `entryPoints[typeID]`.
    public func load(engine: inout Engine, typeID: Int)

    /// Executes exactly one opcode. Returns `.halted` when the engine
    /// cannot continue (invalid opcode, stack overflow, unknown function).
    @discardableResult
    public func step(_ engine: inout Engine) -> RunResult
}

public enum RunResult: Equatable, Sendable {
    case ok        // executed one opcode; engine can step again
    case halted    // engine.halted == true after this call; further step()s are no-ops
}
```

`functions[p]` is invoked for `SCRIPT_FUNCTION` with parameter `p` (masked to 8 bits, per OpenDUNE). A nil slot means "not implemented" and halts the engine (mirrors `scriptInfo->functions[parameter] == NULL`).

## 3. Opcode semantics (mirror of `Script_Run`)

All opcodes consume the first word at `Program.code[pc]`, then optionally a second word when the `0x2000` flag is set on the first. The decoded parameter follows `EmcProgram`'s existing rules; the VM just re-reads the raw word to preserve OpenDUNE's "jump to any word" semantics (a JUMP target might land mid-instruction and OpenDUNE would happily execute that word as an opcode).

| # | Opcode | Effect |
|---|--------|--------|
| 0 | `JUMP` | `pc = parameter` |
| 1 | `SETRETURNVALUE` | `returnValue = parameter` |
| 2 | `PUSH_RETURN_OR_LOCATION` | `p=0` → push `returnValue`; `p=1` → push `pc+1`, push `FP`, set `FP = SP+2`. The `+1` on `pc` accounts for the JUMP-to-subroutine the EMC compiler always emits immediately after the setup (return address = word *after* that JUMP). |
| 3, 4 | `PUSH`, `PUSH2` | push `parameter` |
| 5 | `PUSH_VARIABLE` | push `variables[parameter]` |
| 6 | `PUSH_LOCAL_VARIABLE` | push `stack[FP - parameter - 2]`; halts if `FP-p-2 >= 15` |
| 7 | `PUSH_PARAMETER` | push `stack[FP + parameter - 1]`; halts if `FP+p-1 >= 15` |
| 8 | `POP_RETURN_OR_LOCATION` | `p=0` → `returnValue = pop()`; `p=1` → peek(2) then `FP = pop(); pc = pop()` |
| 9 | `POP_VARIABLE` | `variables[parameter] = pop()` |
| 10 | `POP_LOCAL_VARIABLE` | `stack[FP - parameter - 2] = pop()`; same overflow guard as #6 |
| 11 | `POP_PARAMETER` | `stack[FP + parameter - 1] = pop()`; same overflow guard as #7 |
| 12 | `STACK_REWIND` | `SP += parameter` (deallocate) |
| 13 | `STACK_FORWARD` | `SP -= parameter` (allocate locals) |
| 14 | `FUNCTION` | `p &= 0xFF`; if `p >= 64` or `functions[p] == nil` → halt; else `returnValue = functions[p](&engine, &vm)` |
| 15 | `JUMP_NE` | peek(1); if `pop() != 0` → continue; else `pc = parameter & 0x7FFF` |
| 16 | `UNARY` | `p=0` → `!x`, `p=1` → `-x`, `p=2` → `~x`; anything else halts |
| 17 | `BINARY` | `right = pop(); left = pop();` then one of 18 signed/unsigned operations by `parameter`; `parameter >= 18` halts |
| 18 | `RETURN` | peek(2); `returnValue = pop(); pc = pop(); isSubroutine = false` |

### Halt semantics

Every halt condition in OpenDUNE does three things: emits `Script_Error(...)`, sets `script->script = NULL`, and returns `false`. Our Swift port maps these to `engine.halted = true` and leaves the PC pointing at the offending word. The public `step()` returns `.halted`. Subsequent `step()` calls on a halted engine are no-ops that return `.halted`.

We don't reproduce the `Script_Error` string messages byte-for-byte; they're debug-only in OpenDUNE. The halt *condition* is what matters.

### Peek-before-pop

For opcodes that pop two or more values (`POP_RETURN_OR_LOCATION p=1`, `JUMP_NE`, `RETURN`, `BINARY`), OpenDUNE performs a `STACK_PEEK(n)` first specifically to fail-fast on underflow before clobbering state. We replicate this so a stack with only one value halts cleanly instead of reading garbage.

## 4. Frame-setup quirk

After a `PUSH_RETURN_OR_LOCATION(1)` the stack layout, with example `SP_before = 14` (one argument pushed by the caller) and `FP_before = 17`, becomes:

```
stack[15] = first arg pushed by caller
stack[14] = second arg pushed by caller (if any)
...
stack[FP_new]   = caller's last-pushed arg (highest-indexed remaining slot)
stack[FP_new-1] = saved return location (pc + 1)
stack[FP_new-2] = saved FP
stack[FP_new-3] = first local allocated by STACK_FORWARD
```

With `FP_new = 12` (after our two pushes):

- `PUSH_PARAMETER(1)` → `stack[FP_new + 1 - 1] = stack[12]` — which is the saved FP, not an argument. In practice callers use `p=2, 3, ...` to reach real arguments because the OpenDUNE compiler reserves `p=1` for the saved FP. The VM doesn't enforce this; it faithfully reproduces the indexing.
- `PUSH_LOCAL_VARIABLE(0)` → `stack[FP_new - 0 - 2] = stack[10]` — points at wherever `STACK_FORWARD` has allocated space. Same caveat.

## 5. Public API & construction

```swift
let program = try Formats.Emc.Program.decode(data)
var vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
var engine = Scripting.Engine.reset()
vm.load(engine: &engine, typeID: 3)        // pick an entry point
while case .ok = vm.step(&engine) {}       // run until halted
```

`Engine.reset()` initialises `stackPointer = 15`, `framePointer = 17`, `variables` and `stack` to zeros, `halted = false`. `VM.load(typeID:)` additionally sets `pc = program.entryPoints[typeID]`.

The `delay` / suspension field that OpenDUNE's `ScriptEngine` carries (for tick-based sleep from `Script_General_Delay`) is a property of the function implementations, not the VM itself, so we leave it out of `Engine` for now. When P4 wires in the unit/structure tick, the `Function` callback can set an `engine.delay` field added at that time.

## 6. Testing

`Core/Tests/DuneIICoreTests/EmcVMTests.swift`:

1. **Reset produces the canonical empty engine.** `SP == 15, FP == 17, halted == false`, stack and variables zeroed.
2. **Stack push/pop round-trips.** A synthetic `PUSH 0x1234` → `POP_VARIABLE 0` leaves `variables[0] == 0x1234` and `SP == 15`.
3. **BINARY arithmetic.** `PUSH 5; PUSH 3; BINARY 8` (+) leaves top-of-stack `8`. A few operators (≤, >>, |) cover the signed-shift and signed-comparison paths.
4. **UNARY operators.** `PUSH 0; UNARY 0` → `1`. `PUSH 5; UNARY 1` → `-5` (as `UInt16` bit pattern `0xFFFB`). `PUSH 0x1234; UNARY 2` → `0xEDCB`.
5. **JUMP and JUMP_NE.** Backward `JUMP` loops; `JUMP_NE` with non-zero TOS falls through, with zero TOS takes the branch.
6. **SETRETURNVALUE + PUSH_RETURN_OR_LOCATION 0.** Sets the return value, then pushes it. `stack[14] == parameter`.
7. **STACK_FORWARD + STACK_REWIND.** Allocate 3 locals (SP 15 → 12), then rewind 3 (SP back to 15).
8. **FUNCTION dispatch.** A test-only `Function` that pops its arg and pushes double onto the stack; assert the engine called it exactly once with the right arg.
9. **Halt on unknown BINARY parameter.** `PUSH 0; PUSH 0; BINARY 18` → `.halted`.
10. **Halt on nil function slot.** `FUNCTION 5` with `functions[5] == nil` → `.halted`.
11. **Halt on `RETURN` with empty stack.** Reset engine, single `RETURN` opcode → `.halted`, stack unchanged.
12. **Pinned run.** Load a 6-instruction synthetic program (PUSH 2, PUSH 3, BINARY 10 (*), POP_VARIABLE 0, SETRETURNVALUE 42, RETURN). Before RETURN: `variables[0] == 6`, `returnValue == 42`.

All tests use synthetic `Formats.Emc.Program` instances built via `Program.decodeCode([...])` — no install-dependent fixtures needed.

## 7. Related insights

- `format-emc-variable-instruction-width.md` — why the VM decodes first-word + (optional) second-word at run time.
- Future `scripting-emc-frame-pointer-offsets.md` — once we have a real subroutine trace to point at, capture the "FP-indexed slot 0 is saved FP, not a local" quirk that makes compiled EMC scripts look off-by-one.
