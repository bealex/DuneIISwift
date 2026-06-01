# Save — our native save format (`DuneIIWorld/State/SaveGame.swift`)

Our own save format, distinct from the original Dune II / OpenDUNE `.SAV`. Where the original is an IFF/FORM
chunk container with a descriptor-driven field serializer (and does **not** save the RNG seed), ours saves the
**entire `GameState`** so a load resumes the simulation **bit-identically**.

## Layout

```
offset  size  field
0       4     magic   "DU2S"  (0x44 0x55 0x32 0x53)
4       1     version 1
5       …     body    a binary property list of the GameState
```

The body is `PropertyListEncoder(.binary)`-encoded `GameState`. Foundation-only and deterministic (same state
→ same bytes). `version` is bumped on any incompatible `GameState`-shape change; `load` throws `badVersion`.

## What's captured (and why bit-identical resume works)

`GameState` is `Codable` (synthesized) because every member is: the pools (`units`/`structures`/`houses`/
`teams` + their find arrays), the `map`, the scenario, the tile ids, the in-progress `animations`/`explosions`,
all clocks/cursors/scalars — and, crucially, **both RNGs' internal state** (`Random256`/`RandomLCG` have custom
`Codable` that round-trips their full feedback/state via `rawState`; the transient `traceSink` is excluded).
The `iconMap` asset is saved too, so a loaded game is self-contained.

Because the RNG state and every cursor are preserved, `Simulation(state: load(save(s)))` continues *exactly*
as `s` would have — verified by `SaveGameTests.deterministicResume` (save a mid-game SCENA001, load, run both
80 ticks, assert tick-for-tick agreement). This is the deterministic guarantee the original `.SAV` cannot give
(it omits the seed); a converted original save (`SaveConverter`) resumes only *behaviorally* faithfully.

## API

- `SaveGame.save(_ state: GameState) throws -> Data`
- `SaveGame.load(_ data: Data) throws -> GameState` — throws `SaveError.{truncated,badMagic,badVersion,decode}`.

## The original-`.SAV` converter (`SaveConverter`)

Reads an **original** Dune II / OpenDUNE save (the IFF/FORM `.SAV`) and ingests its *semantic* state into a
`GameState` — **not** a byte-for-byte EMC-VM resume (the EMC script state is skipped and re-seeded; the caller
does the scenario-prep `setAction`, as for an `.INI` load). A converted game continues *behaviorally*
faithfully but not bit-identically (`Plan.v1.md` §2).

Container: a **big-endian** IFF `FORM` (length = total − 8), a `SCEN` marker, then little-endian chunks, each
`tag(4) + length(BE u32) + data + pad-to-even`:

| Chunk | Contents (ported from OpenDUNE `src/save_load/`) |
|---|---|
| `NAME` | description string (skipped) |
| `INFO` | `u16` version + `g_scenario` (228 B: score/win/lose, **mapSeed**, mapScale, kills/harvest, reinforcements) + globals (campaignID, starportAvailable[27], playerCreditsNoSilo, tickScenarioStart, …) = 330 B |
| `PLYR` | houses — 66 B each |
| `UNIT` | units — **128 B** each (Object 71 + 57) |
| `BLDG` | structures — **88 B** each (Object 71 + 17) |
| `MAP ` | sparse tile overrides — `u16` tileIndex + 4-byte packed `Tile`, applied over the seed-regenerated landscape |
| `TEAM` | teams |
| `ODUN` | OpenDUNE's extended unit fields (skipped — we re-derive) |

**Object = 71 bytes**, because it embeds a **55-byte `ScriptEngine`** (delay/script/returnValue/frame+stack
pointers/variables[5]/stack[15]/isSubroutine), which we skip. `playerHouseID` = the house with the `human`
flag. Verified cross-engine by `SaveConverterTests`: the oracle saves a scenario (`--parity-save`) + dumps it,
and the Swift converter must reproduce that dump.

## Reference

The original format is OpenDUNE `src/save_load/` (`save.c`/`load.c` + the `SaveLoadDesc` descriptors).
Regenerate the converter fixture with `Scripts/gen-scenario-goldens.sh --only convert-save` (the oracle's
`--parity-save`). Our format does not interoperate with the original; it is for our own save/quick-load.
