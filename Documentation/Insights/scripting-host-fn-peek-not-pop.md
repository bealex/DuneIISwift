# EMC host functions must peek their args, never pop

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Scripting/Functions.swift`
- **Category**: scripting
- **Applies to**: every entry in a `Scripting.VM` 64-slot function table, `Scripting.Functions` and any future `Script_Unit_*` / `Script_Structure_*` ports.

## The fact

OpenDUNE's `Script_General_*` (and every `Script_Unit_*`, `Script_Structure_*`) host function reads its stack arguments with `STACK_PEEK(n)`, never `STACK_POP()`. The EMC compiler emits call sites like:

```
PUSH <arg1>
PUSH <arg2>
FUNCTION <n>
STACK_REWIND 2        ; <- caller cleans up exactly 2 slots
```

The `STACK_REWIND` is the caller's responsibility. If a host function pops its own arguments, the subsequent `STACK_REWIND` runs against the wrong stack depth and silently corrupts whatever lives below — usually the saved frame pointer or return location, so the crash happens far away from the actual bug.

`Script_General_Delay` (which writes `engine.delay`) is the easy one to mis-port — the "obvious" Swift idiom is `let ticks = pop(engine: &engine)`. That version passes every test that doesn't involve a real compiled script, and then explodes the first time a DUNE.PAK EMC tries to delay an idling unit.

## Why it matters

A "tidier" Swift port that consumes its arguments matches the C prototype but diverges from the compiler's calling convention. The fallout is stack-corruption bugs that surface far from the actual site. Mirror the OpenDUNE convention exactly: host functions read via `peek` and return a `UInt16`; the VM assigns the return value to `engine.returnValue` and lets the next `STACK_REWIND` clean up.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Scripting/Functions.swift` — `Functions.delay`, `Functions.noOperation`, and the `makeRandomRange` closure factory all use `Scripting.peek(engine:position:)`.
- `Code/Core/Sources/DuneIICore/Scripting/Scripting.swift` exposes `peek`, `pop`, `push` as the public stack primitives for host callbacks — `peek` is the intended default.
- `Tests/DuneIICoreTests/EmcFunctionsTests.swift::delayDividesByFive` asserts `stackPointer == 14` after the call, guarding against accidental pops.

## Where it lives in the reference

OpenDUNE `src/script/general.c`, `src/script/unit.c`, `src/script/structure.c` — every function body uses `STACK_PEEK(n)` exclusively. The `STACK_POP` idiom is reserved for the VM's own opcodes (`SCRIPT_BINARY`, `SCRIPT_RETURN`, `SCRIPT_POP_VARIABLE`, etc.) in `src/script/script.c::Script_Run`.
