# OpenDUNE save records embed a 55-byte ScriptEngine — Object is 71 bytes, not 38

**Finding:** A serialized OpenDUNE `Object` is **71 bytes** because it embeds a **55-byte `ScriptEngine`**
(`g_saveScriptEngine`: delay 2 + script 4 + empty 4 + returnValue 2 + framePointer 1 + stackPointer 1 +
variables[5] 10 + stack[15] 30 + isSubroutine 1). So a saved `Unit` is **128 B** (71 + 57) and a `Structure`
is **88 B** (71 + 17). A `House` is 66 B (no script).

**Why it matters:** Getting a record size wrong by even one byte misaligns every following record, so the
converter reads garbage from the second unit on. An automated read of the `SaveLoadDesc` lists reported
"ScriptEngine = 22 B / Object = 38 B" (it mis-summed the script and/or confused in-memory padding with the
on-disk layout). Always derive on-disk sizes by **summing the `SLD_*` field disk types yourself**
(`SLDT_UINT16`=2, `SLDT_UINT32`=4, `SLD_ARRAY count×size`, nested `SLD_SLD`=that descriptor's length), not
from a summary. Verify empirically: the IFF chunk length divided by your record size must be a whole count
(±1 pad byte).

**Evidence:** `SaveConverter` record-size constants + the field-by-field readers; `SaveConverterTests`
(cross-engine vs the oracle's `--parity-save` dump); OpenDUNE `src/save_load/scriptengine.c` (the 55-byte
descriptor), `object.c`, `unit.c`, `structure.c`, `house.c`. The INFO chunk is 330 B = `u16` version + 228 B
`g_scenario` + 100 B globals (campaignID at INFO-offset 254).

**How to apply:** When porting a descriptor-driven binary format, port the descriptor field-by-field and
compute sizes from the disk types; cross-check against a real file's chunk lengths. For a save *converter*,
skip the EMC `ScriptEngine` (we re-seed the state machines) — but still advance the reader by its exact 55
bytes.
