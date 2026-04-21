# EMC instructions are 1 or 2 u16 words, chosen by flag bits in the first word

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Emc/EmcProgram.swift`
- **Category**: format
- **Applies to**: `Formats.Emc.Program`, the future script VM in `Core/Simulation/Scripting/`.

## The fact

Each EMC instruction starts with a big-endian `u16`. Three top bits decide the shape:

| Flag bits    | Meaning                                                     |
|--------------|-------------------------------------------------------------|
| `0x8000` set | 13-bit `JUMP` with parameter `word & 0x7FFF`. Opcode forced to 0. |
| `0x4000` set | Parameter is the sign-extended low byte (`(Int8)(word & 0xFF)`). |
| `0x2000` set | Parameter is the **next** full u16 big-endian word (instruction is 2 words). |
| none         | Parameter is 0.                                             |

In every shape except the first, the opcode itself is `(word >> 8) & 0x1F` — only the low 5 bits of the high byte, so there are 32 possible opcodes of which 19 are defined.

The VM has to advance its instruction pointer by 1 or 2 words accordingly. Our parser pre-computes this — `Instruction.wordSize` is 1 or 2, and `Program.wordIndexToInsn` maps every word offset (including the middle word of a 2-word instruction) back to its owning `Instruction` so jumps to mid-stream addresses can be resolved.

## Why it matters

Treating every instruction as a single word produces an opcode stream that desynchronises after the first `PUSH_PARAMETER` with a 16-bit literal — all subsequent decodes read into the wrong bytes. The pattern is easy to miss because the simplest opcodes (`JUMP`, `RETURN`) are all single-word.

## Where it lives in our code

- `Formats.Emc.Program.decodeFromCode` — the flag-bit dispatch.
- `Tests/DuneIICoreTests/EmcTests.swift::twoWordParameter` and `::wordToInsnMapping` cover the 2-word branch.

## Where it lives in the reference

OpenDUNE `src/script/script.c::Script_Run`:

```c
current = BETOH16(*script->script);
script->script++;
opcode = (current >> 8) & 0x1F;
if ((current & 0x8000) != 0) { opcode = 0; parameter = current & 0x7FFF; }
else if ((current & 0x4000) != 0) { parameter = (int16)(int8)(current & 0xFF); }
else if ((current & 0x2000) != 0) { parameter = BETOH16(*script->script); script->script++; }
```
