# EMC script VM (`Script_Run`)

The bytecode interpreter that drives every unit/structure/team behaviour. Each object owns a `ScriptEngine` (a small register/stack machine); a `ScriptInfo` holds the loaded program (the EMC `DATA` words + the per-type `ORDR` entry offsets). The per-tick game loop steps an object's engine a bounded number of opcodes (`SCRIPT_UNIT_OPCODES_PER_TICK = 50`). Reference: OpenDUNE `src/script/script.c` (`Script_Run` `:323`, the stack ops `:189–260`, `Script_Reset`/`Load`/`LoadAsSubroutine`/`IsLoaded` `:264–321`) and `src/script/script.h` (the `ScriptCommand` enum + the struct layouts).

This block ports the **VM core** only. The three concerns split cleanly:
1. **VM core** (this block) — the interpreter, the stack, and load/reset. Testable in isolation with synthetic bytecode.
2. **`ScriptInfo` from EMC** — bridging `Emc.Program` (the existing Formats reader: `DATA` words + `ORDR` offsets) into a `ScriptInfo`. Done here as a small initializer.
3. **The native function tables** (`g_scriptFunctionsUnit/Structure/Team`, 64 each) — ported incrementally, one per state-machine slice. The VM reaches them through an injected dispatch closure (op 14), so the core needs none of them yet.

## Model mapping (pointer → offset)

OpenDUNE keeps `script->script` as a raw pointer into the BE16 program and `scriptInfo->start` as its base, so the live "program counter" is `script->script - scriptInfo->start`. We already store that subtraction as `ScriptEngine.scriptPC` (a word offset), and `Emc.Program.data` is pre-decoded to host-order `UInt16`, so the VM reads `program[scriptPC]` directly (no `BETOH16`). A NULL `script` pointer (reset, or after a fatal scripting error) is represented by the sentinel `scriptPC == 0xFFFF` (`ScriptEngine.scriptNull`); `isLoaded` is `scriptPC != scriptNull`.

## Stack

`stack[15]`, filling from the **end**: `stackPointer` starts at 15 (empty). `push`: error if SP == 0, else `stack[--SP] = v`. `pop`: error if SP ≥ 15, else `stack[SP++]`. `peek(pos)` (1-based): error if SP ≥ 16 − pos, else `stack[SP + pos − 1]`. `framePointer` starts at 17. A stack over/underflow sets `scriptPC = scriptNull` (the NULL-PC error state) — we drop OpenDUNE's `Script_Error` logging.

## One opcode (`Script_Run` → `step`)

Read `current = program[scriptPC]`, advance PC. `opcode = (current >> 8) & 0x1F`. The parameter comes from one of three encodings: bit 0x8000 ⇒ a 13-bit GOTO (opcode forced to 0, parameter = `current & 0x7FFF`); bit 0x4000 ⇒ parameter is the sign-extended low byte; bit 0x2000 ⇒ parameter is the next program word (PC advances again). Then dispatch:

| op | name | effect |
|----|------|--------|
| 0  | JUMP | `scriptPC = parameter` |
| 1  | SETRETURNVALUE | `returnValue = parameter` |
| 2  | PUSH_RETURN_OR_LOCATION | param 0: push `returnValue`; param 1: push `PC+1` then `framePointer`, set `framePointer = SP + 2` |
| 3,4| PUSH / PUSH2 | push `parameter` |
| 5  | PUSH_VARIABLE | push `variables[parameter]` |
| 6  | PUSH_LOCAL_VARIABLE | push `stack[framePointer − parameter − 2]` (bounds-checked) |
| 7  | PUSH_PARAMETER | push `stack[framePointer + parameter − 1]` (bounds-checked) |
| 8  | POP_RETURN_OR_LOCATION | param 0: `returnValue = pop`; param 1: `framePointer = pop`, `scriptPC = pop` |
| 9  | POP_VARIABLE | `variables[parameter] = pop` |
| 10 | POP_LOCAL_VARIABLE | `stack[framePointer − parameter − 2] = pop` |
| 11 | POP_PARAMETER | `stack[framePointer + parameter − 1] = pop` |
| 12 | STACK_REWIND | `stackPointer += parameter` |
| 13 | STACK_FORWARD | `stackPointer −= parameter` |
| 14 | FUNCTION | `returnValue = functions[parameter & 0xFF](engine)`; invalid index ⇒ error (no NULL-PC) |
| 15 | JUMP_NE | `pop`; if non-zero return; else `scriptPC = parameter & 0x7FFF` |
| 16 | UNARY | param 0 `!`, 1 `-`, 2 `~` on top of stack |
| 17 | BINARY | pop right, pop left, push one of `&& \|\| == != < <= > >= + - * / >> << & \| % ^` (params 0–17), as signed `int16` |
| 18 | RETURN | `returnValue = pop`, `scriptPC = pop`, `isSubroutine = 0` |

`step` returns `false` on a scripting error or when the engine isn't loaded (matching `Script_Run`), `true` otherwise. Arithmetic is signed 16-bit and wraps (matching the C `int16`), so we use `&+`/`&-`/`&*` and `Int16(truncatingIfNeeded:)`.

## Load

- `reset` (`Script_Reset`): `scriptPC = scriptNull`, `isSubroutine = 0`, `framePointer = 17`, `stackPointer = 15`. (The `scriptInfo` pointer isn't stored — it's supplied to `run`/`load` per call, re-derived from the owner's type.)
- `load` (`Script_Load`): `reset`, then `scriptPC = offsets[typeID]`.
- `loadAsSubroutine` (`Script_LoadAsSubroutine`): only if already loaded and not already a subroutine; push `PC` then `returnValue`, set `isSubroutine = 1`, `scriptPC = offsets[typeID]`.

## Placement & seam

`ScriptInfo` + `ScriptInterpreter` (protocol) + `DefaultScriptInterpreter` live in `DuneIISimulation/Script/`, injected into `Simulation` like the other replaceable primitives — which also gives the parity harness's instrumented/tracing variant a home (OpenDUNE traces `Script_Run` via `g_parityScriptTrace`). `Script_Reset`'s field resets stay on the `ScriptEngine` POD (`reset()`, World) since they're pure state. Op-14 dispatch is a `(Int, inout ScriptEngine) -> UInt16?` closure passed to `run` (nil ⇒ unknown function ⇒ error); the real per-category native tables (which need `GameState` + the current object) wire through it when they land.

## Testing

Synthetic bytecode programs with hand-derived expected `(scriptPC, stack, returnValue, framePointer)` after each step — one per opcode/encoding (the three parameter encodings; push/pop/peek bounds; the subroutine call/return frame protocol; every binary/unary op; JUMP/JUMP_NE both ways; op-14 dispatch via an injected counter closure; the not-loaded / overflow error → `scriptPC == scriptNull`). The full per-script decision-trace golden (the oracle's `g_parityScriptTrace`) lands once the native function tables exist and a real script can run end-to-end.
