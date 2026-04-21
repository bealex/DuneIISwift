# EMC — Compiled game script

Status: Documented 2026-04-19

EMC holds the stack-based byte code that drives every structure, unit, and AI team in Dune II. Files land in the PAKs as `BUILD.EMC`, `UNIT.EMC`, and `TEAM.EMC`. The file is a container only — the actual VM (which dispatches opcodes against per-entity state) is a P4 concern; P1 delivers the byte-level parser that feeds it.

References:

- OpenDUNE `src/script/script.c` · `Script_LoadFromFile` walks the IFF chunks; `Script_Run` decodes individual opcodes.
- OpenDUNE `src/script/script.h` · the `SCRIPT_*` opcode enum.
- Our decoder: `Formats.Emc.Program` in `Code/Core/Sources/DuneIICore/Formats/Emc/`.

## 1. Container

EMC is an IFF `FORM` with three chunks. The outer form tag is `EMC ` (unused by us).

| Tag    | Purpose                                                          |
|--------|------------------------------------------------------------------|
| `TEXT` | String table used by display-text opcodes.                       |
| `ORDR` | `u16 BE` offsets into the code, one per entry point.             |
| `DATA` | The compiled opcode stream (`u16 BE` values).                    |

Chunk length is big-endian like the IFF spec. ICN uses the same walker; see [ICN.md](ICN.md).

## 2. TEXT — string pool

Layout inside the chunk:

```
offset[0]   u16 BE   — byte position of string 0 within the chunk
offset[1]   u16 BE   — byte position of string 1
...
offset[N-1] u16 BE   — byte position of string N-1
```

The count `N` is implicit: `N = offset[0] / 2`, since `offset[0]` is exactly where the offset table ends and the string pool begins.

Each string is 7-bit ASCII, NUL-terminated. OpenDUNE grabs them via `(char *)text + BE16(text[index])`.

## 3. ORDR — entry points

`(length / 2)` u16 BE values. Each is an index into `DATA` (u16 word offset, not byte offset). Structures index by state, units by action, etc. — the caller knows which slot maps to which semantic.

## 4. DATA — opcode stream

Each instruction is **1 or 2 u16 BE words**.

```
word = nextU16BE()

if word & 0x8000:
    opcode    = 0 (JUMP)
    parameter = word & 0x7FFF    (13-bit absolute address, in words)
elif word & 0x4000:
    opcode    = (word >> 8) & 0x1F
    parameter = (sign-extended) (Int8)(word & 0xFF)
elif word & 0x2000:
    opcode    = (word >> 8) & 0x1F
    parameter = nextU16BE()      (second word)
else:
    opcode    = (word >> 8) & 0x1F
    parameter = 0
```

Opcodes (from `script.h`):

| ID | Name                    | Parameter semantics                        |
|----|-------------------------|--------------------------------------------|
| 0  | JUMP                    | Absolute word address                      |
| 1  | SETRETURNVALUE          | Literal value                              |
| 2  | PUSH_RETURN_OR_LOCATION | 0: push return; 1: push location+fp        |
| 3  | PUSH                    | Literal                                    |
| 4  | PUSH2                   | Same as PUSH                               |
| 5  | PUSH_VARIABLE           | Variable index (0…4)                       |
| 6  | PUSH_LOCAL_VARIABLE     | Frame-pointer-relative slot                |
| 7  | PUSH_PARAMETER          | Frame-pointer-relative slot                |
| 8  | POP_RETURN_OR_LOCATION  | 0: pop return; 1: pop location+fp          |
| 9  | POP_VARIABLE            | Variable index                             |
| 10 | POP_LOCAL_VARIABLE      | Local slot                                 |
| 11 | POP_PARAMETER           | Parameter slot                             |
| 12 | STACK_REWIND            | stackPointer += parameter                  |
| 13 | STACK_FORWARD           | stackPointer -= parameter                  |
| 14 | FUNCTION                | Low byte = function ID for the type-specific table |
| 15 | JUMP_NE                 | Word address; jumps if TOS != 0            |
| 16 | UNARY                   | 0:!x, 1:-x, 2:~x                           |
| 17 | BINARY                  | 0:&&, 1:\|\|, 2:==, 3:!=, 4:<, 5:<=, 6:>, 7:>=, 8:+, 9:-, 10:\*, 11:/, 12:>>, 13:<<, 14:&, 15:\|, 16:%, 17:^ |
| 18 | RETURN                  | (no parameter)                             |

Only 19 opcodes are defined (`>> 8 & 0x1F` leaves room for 32); any other value indicates corruption. Our parser records the raw word and the decoded opcode/parameter, *plus* a "word size" (1 or 2) so the P4 VM can advance the instruction pointer correctly.

## 5. Swift API

```swift
let data = pak.body(named: "UNIT.EMC")!
let program = try Formats.Emc.Program.decode(data)

// Inspect entry points
let firstEntry = program.entryPoints[0]        // UInt16 word index
let firstInsn = program.instruction(atWord: Int(firstEntry))

// String table
let firstText = program.texts[0]               // "I'm tired..."
```

`Program.instructions` is a flat array — parallel to `code` — where every entry records `(opcode, parameter, rawWord, wordSize)`. For a 2-word instruction, the second word's position in `code` has no matching `Instruction`; `wordIndexToInsn` maps word → instruction index so callers can navigate mid-stream jumps.

## 6. Testing

`Core/Tests/DuneIICoreTests/EmcTests.swift`:

1. Synthetic instruction decode:
   - 0x8007 → JUMP with parameter 7.
   - 0x4342 → opcode 3 (PUSH) with parameter -66 (sign-extended 0x42 → 0x42 = +66 actually — use 0xC0 for −64).
   - 0x2700 then 0x1234 → opcode 7, parameter = 0x1234.
2. Invalid opcode (e.g. 0x1F bits set to a non-existent id like 31) is rejected.
3. TEXT chunk roundtrip: build a synthetic EMC with two strings and verify `texts` equals the input.
4. Real `UNIT.EMC` decodes: `entryPoints.count > 0`, `instructions` non-empty, every opcode within `0…18`.

## 7. Related insights

- [format-emc-variable-instruction-width](../Insights/format-emc-variable-instruction-width.md) — one or two u16 words per instruction, driven by bit flags.
