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

## Reference

The original format is OpenDUNE `src/save_load/` (`save.c`/`load.c` + the `SaveLoadDesc` descriptors). We read
it only via the **converter** (semantic ingest, not a byte-for-byte VM resume) — see `SaveConverter` + the
converter notes. Our format does not interoperate with the original; it is for our own save/quick-load.
