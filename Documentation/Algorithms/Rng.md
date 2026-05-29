# Random number generators

Dune II has **two** independent PRNGs. Both are ported bit-exactly; `GameState` will own the live instances (mutable RNG state belongs in the one aggregate). Verified against an OpenDUNE golden dump — see `../Architecture/FunctionParityHarness.md`.

## `Tools_Random_256` — 3-byte feedback generator (returns a byte)

OpenDUNE `src/tools.c:268` (`Tools_Random_Seed` at `:308`). State is 3 active bytes (`s_randomSeed[0..2]`; a 4th seed byte is unpacked but unused). Each call:

```
val16 = (seed1 << 8) | seed2
val8  = ((val16 ^ 0x8000) >> 15) & 1        # inverted top bit of val16
val16 = (val16 << 1) | ((seed0 >> 1) & 1)   # uint16 — bit 15 shifted out
val8  = (seed0 >> 2) - seed0 - val8         # uint8 wrap
seed0 = (val8 << 7) | (seed0 >> 1)          # uint8 — only bit0 of val8 survives
seed1 = val16 >> 8
seed2 = val16 & 0xFF
return seed0 ^ seed1
```

Seeded little-endian from a 32-bit value (`seed0 = v & 0xFF`, `seed1 = (v>>8)&0xFF`, `seed2 = (v>>16)&0xFF`). The wrapping `uint8`/`uint16` arithmetic is the whole point — the Swift port uses `&-` and fixed-width shifts (`Random256.next()`). Scripts reach it via `General_DelayRandom`, `Unit_RandomSoldier`, `Unit_GetRandomTile`, etc.

## `Tools_RandomLCG` — Borland LCG (returns 0…32767)

OpenDUNE `src/tools.c:327` (`_Seed` at `:319`, `_Range` at `:341`). The original was built with Borland C, so its `rand()` constant leaks into gameplay:

```
state = 0x015A4E35 * state + 1     # uint32 wrap
return (state >> 16) & 0x7FFF       # bits 30..16
```

`Tools_RandomLCG_Range(min, max)` → uniform inclusive `[min, max]`:

```
if min > max: swap
do:
    value = (int32)LCG() * (max - min + 1) / 0x8000 + min   # span computed in int32 (the +1 can't wrap)
    ret = (uint16)value
while ret > max
return ret
```

The span is computed in 32-bit (as C int-promotion does) so a full `[0, 65535]` span's `+1` doesn't wrap. For span ≤ 32768 the result is always ≤ max, so the rejection loop never actually rejects — but it is a `do/while`, so the body always runs once and consumes exactly one draw. The `[0, 32767]` range is the identity scaling, so its stream equals the raw `next()` sequence (used to pin the bare generator). Scripts reach `_Range` via `General_RandomRange`.

## Golden fixture

`Code/Tests/WorldTests/Fixtures/rng-golden.jsonl` — committed output of `opendune --parity-golden=<dir>`. Covers `Tools_Random_256` over seeds `{0, 1, 0xC0DE, 0x12345678, 0xFFFFFFFF}` (256 bytes each) and `Tools_RandomLCG_Range` over seeds `{0, 1, 0x1234, 0x7FFF}` × ranges `{[0,32767], [0,1], [0,100], [1,6], [5,5], [100,0], [0,255]}` (64 values each; `[100,0]` exercises the swap, `[5,5]` the degenerate span). Regenerate: rebuild the patched OpenDUNE (`FunctionParityHarness.md`) and re-run the flag; recommit the file. Asserted by `WorldTests/RngGoldenTests`.
