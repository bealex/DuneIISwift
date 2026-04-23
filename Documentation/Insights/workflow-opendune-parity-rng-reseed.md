# OpenDUNE save-load does not restore RNG state; LCG seed from `time(NULL)` leaks non-determinism

- **Discovered**: 2026-04-23 · `Documentation/Architecture/opendune-parity-patch/tick_parity_dump.patch`
- **Category**: workflow
- **Applies to**: any harness that reproduces OpenDUNE behaviour from a save file

## The fact

`OpenDune_Init` (`src/opendune.c:1193`) seeds the LCG with `Tools_RandomLCG_Seed((unsigned)time(NULL))`. `SaveGame_LoadFile` (`src/load.c:131`) does *not* restore either the LCG or the 4-byte random seed — neither is in the save file's table walker. `Tools_Random_Seed` is only called from `map.c:1455` inside `Game_LoadScenario`, which `SaveGame_LoadFile` does **not** invoke. So after a save-load, the LCG still carries whatever wall-clock-derived seed `OpenDune_Init` set.

Our tick-parity capture tool caught this the obvious way: two back-to-back `./bin/opendune --parity-load=_SAVE001.DAT --parity-ticks=200 --parity-dump=...` runs produced byte-identical output through tick 20 and then diverged on the very next tick — whenever the sim first drew from the LCG (team AI, idle-action jitter, muzzle flash spawn position, etc.).

The fix, in `parity.c`, is to re-seed both generators twice:

```c
Tools_RandomLCG_Seed(0);
Tools_Random_Seed(0);
SaveGame_LoadFile(...);
Tools_RandomLCG_Seed(0);   /* Game_Prepare consumes RNG during setup */
Tools_Random_Seed(0);
```

Pre-load is not enough: `SaveGame_LoadFile` calls `Game_Prepare` (unless `g_gameMode == GM_RESTART`), and that path touches the RNG before control returns.

## Why it matters

Anything that "replays OpenDUNE from a save" must pin both RNGs *after* `SaveGame_LoadFile` completes or the run is not reproducible. This applies to:

- The tick-parity harness (committed fixture would drift between regenerations).
- Any future bisect / minimiser that plays back a save hoping to reproduce a bug — you'd chase ghosts if the sim path depends on the LCG and the LCG depends on the wall clock.
- Anyone porting additional OpenDUNE tools over should assume RNG is *never* round-tripped by save/load, unlike pool state.

Our Swift side is fine here: `Simulation.WorldSnapshot.init(save:)` doesn't carry RNG state across either (we construct a fresh `BorlandLCG` at known seeds), and the harness will feed the same deterministic start to both engines.

## Where it lives in our code

- `Repositories/OpenDUNE/src/parity.c` (applied from the committed patch) — the double-seed pattern is documented in a comment at the call site.
- `Documentation/Architecture/opendune-parity-patch/README.md` — "Verifying determinism" section points at this insight.

## Where it lives in the reference

- `src/opendune.c:1193` — `Tools_RandomLCG_Seed((unsigned)time(NULL))`.
- `src/load.c:131–162` — `SaveGame_LoadFile`: no `Tools_Random_Seed` / `Tools_RandomLCG_Seed` call on any branch.
- `src/saveload/info.c` — the `s_saveInfo` table: no RNG entries.
- `src/tools.c:17–18` — `s_randomSeed[4]` and `s_randomLCG` are `static`, so they're unreachable from anywhere other than `tools.c` itself; adding a getter would require touching that file, which the parity design doc's no-touch list forbids.
