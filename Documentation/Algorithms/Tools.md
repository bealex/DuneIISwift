# Tools_* primitives

Misc native helpers from OpenDUNE `src/tools.c`, ported bit-exactly and golden-verified — see `../Architecture/FunctionParityHarness.md`. Swift: `DuneIIWorld/Tools/`. (The two RNGs also live in tools.c — documented separately in `Rng.md`.)

## `Tools_AdjustToGameSpeed` (`tools.c:20`)

Scales a "normal" duration (tick count) for the current game speed. `gameSpeed` is 0 (slowest) … 4 (fastest), 2 = normal. In OpenDUNE it reads `g_gameConfig.gameSpeed`; in our port it is a parameter (the setting will live in `GameState`).

```
if gameSpeed == 2 or gameSpeed > 4: return normal
clamp: maximum = min(maximum, normal*2);  minimum = max(minimum, normal/2)
if inverseSpeed: gameSpeed = 4 - gameSpeed       # slower-when-faster things
switch gameSpeed:
  0 -> minimum
  1 -> normal - (normal - minimum)/2
  3 -> normal + (maximum - normal)/2
  4 -> maximum
```

The clamp assignments truncate back to `uint16` before reuse; the port mirrors that and computes the rest in `Int`, truncating on return. Golden fixture `gamespeed-golden.jsonl`: every `gameSpeed` 0…6 (5–6 hit the `> 4` guard) × `inverse` {0,1} × 6 `(normal,min,max)` cases. Asserted by `WorldTests/ToolsGoldenTests`.

## Encoded indices

A 16-bit "encoded index" tags an object by type in its top two bits, so scripts can pass "unit 5" / "structure 3" / "tile (x,y)" through one `uint16`.

- `Tools_Index_GetType(encoded)` (`tools.c:48`): `encoded & 0xC000` → `0x4000` unit, `0x8000` structure, `0xC000` tile, else none (`IndexType`, `tools.h:9`).
- `Tools_Index_Decode(encoded)` (`tools.c:64`): for a **tile**, X/Y are stored as `(coord*2)+1` in bits 1-6 / 8-13, so decode is `Tile_PackXY((encoded >> 1) & 0x3F, (encoded >> 8) & 0x3F)`; otherwise the bare index is `encoded & 0x3FFF`.

Golden fixture `index-golden.jsonl`: `GetType` + `Decode` over 14 encoded values spanning all four type tags.

**Deferred (need the object pools, arrive with the World model):** `Tools_Index_Encode` (its unit case checks pool allocation), `Tools_Index_IsValid`, and `Tools_Index_GetUnit`/`GetStructure`/`GetTile`/`GetObject`.
