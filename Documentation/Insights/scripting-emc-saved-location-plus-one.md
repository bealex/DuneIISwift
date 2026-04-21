# EMC `PUSH_RETURN_OR_LOCATION 1` saves `pc + 1`, not `pc`

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Scripting/Scripting.swift`
- **Category**: scripting
- **Applies to**: EMC VM (`Scripting.VM`), EMC compiler reverse-engineering, save/load round-tripping of paused engines.

## The fact

The EMC subroutine prologue is `PUSH_RETURN_OR_LOCATION 1`, which OpenDUNE implements as:

```c
location = (uint32)(script->script - scriptInfo->start) + 1;
STACK_PUSH(location);
STACK_PUSH(script->framePointer);
script->framePointer = script->stackPointer + 2;
```

The `+1` looks like an off-by-one bug — naive readers expect the saved return address to be the next executable word. It is **not a bug**. The EMC compiler's calling convention always emits a `JUMP` immediately after `PUSH_RETURN_OR_LOCATION 1`:

```
... arg pushes ...
PUSH_RETURN_OR_LOCATION 1     ; save (pc + 1) and old FP
JUMP <subroutine_start>       ; this JUMP is the +1 the caller skips on RETURN
... return target lands here ...
```

So when `RETURN` later does `pc = pop()`, it lands on the word *after* the JUMP, which is exactly what the caller wanted. Any port that "fixes" the `+1` will silently corrupt every subroutine call: the first opcode after the call will be re-executed.

## Why it matters

A clean port that saves `pc` and computes the JUMP-skip on the return side gets wrong behaviour from any compiled EMC: every subroutine returns to the JUMP word and re-jumps into the subroutine, looping forever. Mirror the `+1` literally.

This also constrains save-format design: a paused engine carries its `pc` value, and reloading it after a code-layout change (e.g. shipping a new subroutine) requires the layout to match exactly — the saved location has no "this came from PUSH_RETURN_OR_LOCATION" marker.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Scripting/Scripting.swift`, `case 2` (PUSH_RETURN_OR_LOCATION) — `let location = UInt16(truncatingIfNeeded: engine.pc + 1)`.
- The corresponding `case 18` (RETURN) and `case 8 / parameter == 1` (POP_RETURN_OR_LOCATION) just `pc = pop()` — no compensation needed because the saved value already accounts for the trailing JUMP.

## Where it lives in the reference

OpenDUNE `src/script/script.c::Script_Run`, `case SCRIPT_PUSH_RETURN_OR_LOCATION`:

```c
location = (uint32)(script->script - scriptInfo->start) + 1;
STACK_PUSH(location);
```

The behaviour is exercised by every compiled `*.EMC` script in `DUNE.PAK` whose disassembly contains the `PUSH 1; PUSH_RETURN_OR_LOCATION 1; JUMP <sub>` pattern (i.e. virtually all of them).
