# EMC (script bytecode)

The compiled bytecode that drives unit/structure/team behavior (`UNIT.EMC`, `BUILD.EMC`, `TEAM.EMC`). We **disassemble** it (we do not execute it) so the per-type state machines can be transcribed exactly in Phase 3. Reference: OpenDUNE `Script_LoadFromFile` (`src/script/script.c:650`) + the instruction decode in `Script_Run` (`src/script/script.c:323`) + the function tables (`src/script/script.c:42-159`). Port: `Code/Frameworks/DuneIIFormats/Formats/Emc/Emc.swift`. Tool: `assetgen emc-disasm <file.EMC> [unit|structure|team]`. Tests: `Code/Tests/FormatsTests/EmcTests.swift`.

## Layout

An IFF/FORM container (see `Iff.md`) with chunks: `TEXT` (string table), `ORDR` (per-type entry offsets — big-endian uint16 *word* indices into DATA), and `DATA` (big-endian uint16 bytecode words).

## Instruction encoding

Each instruction is a big-endian word: `opcode = (word >> 8) & 0x1F`. Operand by flag bits: `0x8000` → forced `Jump`, operand = `word & 0x7FFF`; `0x4000` → operand = sign-extended `word & 0xFF`; `0x2000` → operand = the next word; otherwise no operand. There are 19 opcodes (`Jump … Return`); opcode `14` = `Function`, whose operand (`& 0xFF`) indexes the per-kind native-function table (e.g. `Unit_Fire`, `Structure_RefineSpice`, `Team_FindBestTarget`). A disassembled type runs from its ORDR entry to the next entry's address.
