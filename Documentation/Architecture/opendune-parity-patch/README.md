# OpenDUNE tick-parity patch

Applies on top of vanilla OpenDUNE (`master` at the time of writing,
commit `60019e8` or newer should work). Adds four CLI flags plus a
deterministic fast-forward mode that dumps per-tick pool state as JSONL.

See `../TickParityHarness.md` for the design; this file is the build +
regenerate recipe.

## What the patch does

Changes to existing files:

- `src/opendune.c` — calls `Parity_ParseArgs` early in `main()`; if
  `--parity-*` flags are present, sets `SDL_VIDEODRIVER=dummy`, pins both
  data directories via `File_SetDataDir`/`File_SetPersonalDataDir`, skips
  `Drivers_All_Init`, skips the `Timer_Add(Timer_Tick, …)` and
  `Timer_Add(Video_Tick, …)` registrations in `OpenDune_Init`, and
  short-circuits `GameLoop_Main`'s state machine to `Parity_Run()`.
- `src/file.c` + `src/file.h` — adds `File_SetDataDir` /
  `File_SetPersonalDataDir` with "override" flags that suppress
  `File_Init`'s ini / HOME / bundle fallbacks when set.
- `source.list` — registers `src/parity.c` and `src/parity.h`.

New files:

- `src/parity.c` — CLI parse, JSONL emitter (houses / structures / units
  in pool-index-ascending order), `Parity_Run()` tight loop. Re-seeds
  `Tools_RandomLCG_Seed(0)` + `Tools_Random_Seed(0)` both before and
  after `SaveGame_LoadFile` for deterministic reproduction (OpenDUNE
  normally seeds the LCG from `time(NULL)` in `OpenDune_Init`).
- `src/parity.h` — public API.

Files deliberately **not** touched, per the design doc:
`src/unit.c`, `src/structure.c`, `src/team.c`, `src/house.c`,
`src/script/*`, `src/map.c`, `src/pool/*`, `src/tools.c`, `src/table/*`.

## Build (macOS Apple Silicon, SDL2 from Homebrew)

```
cd Repositories/OpenDUNE
git apply ../../Documentation/Architecture/opendune-parity-patch/tick_parity_dump.patch

# Homebrew's sdl2-config may not be on the default shell PATH. If not,
# drop a shim somewhere git-ignored and point configure at it:
mkdir -p .shim
printf '%s\n' '#!/bin/bash' 'exec bash /opt/homebrew/bin/sdl2-config "$@"' > .shim/sdl2-config
chmod +x .shim/sdl2-config

SYSROOT="$(xcrun --show-sdk-path)"
CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  ./configure --with-sdl2=$(pwd)/.shim/sdl2-config --with-osx-sysroot="$SYSROOT"
make -j CXX="$(xcrun --find clang++) -isysroot $SYSROOT"
```

The `CXX` override with `-isysroot` is needed because `Makefile.src.in`
builds the tiny `depend` C++ helper without passing sysroot via
`CFLAGS_BUILD`.

## Generate the golden fixtures

The `ParityGoldens/*.jsonl` files are **not committed** to the repo
(they're listed in `.gitignore`). The parity tests short-circuit when
they're missing, so a fresh checkout builds and the rest of the suite
stays green. Regenerate them locally whenever you want to run the
parity tests:

```
INSTALL="$(cd ../../Repositories/patched_107_unofficial && pwd)"   # or wherever v1.07 lives
GOLDENS="$(cd ../../Code/Core/Tests/DuneIICoreTests/Fixtures/ParityGoldens && pwd)"

./bin/opendune \
    --parity-data-dir="$INSTALL" \
    --parity-load=_SAVE001.DAT \
    --parity-ticks=200 \
    --parity-dump="$GOLDENS/save001_200ticks.jsonl"

./bin/opendune \
    --parity-data-dir="$INSTALL" \
    --parity-load=_SAVE007.DAT \
    --parity-ticks=1000 \
    --parity-dump="$GOLDENS/save007_ticks.jsonl"
```

On an M-series Mac each run completes in roughly one wall-clock second
(the sim loop itself is a handful of ms; most time is PAK init).

## Verifying determinism

Running the binary twice with the same inputs must produce byte-identical
dumps. If `diff` shows differences, the RNG is leaking wall-clock state
— inspect any `time(NULL)` / `clock()` calls that happen between
`SaveGame_LoadFile` and the first `Parity_DumpTick`, and re-seed.

## CLI reference

| Flag | Required | Notes |
|---|---|---|
| `--parity-data-dir=<path>` | yes | Install root. PAKs and `_SAVE*.DAT` live here. Both `g_dune_data_dir` and `g_personal_data_dir` get pinned to this path. |
| `--parity-load=<save>` | yes | Filename (not path), resolved under `--parity-data-dir`. E.g. `_SAVE001.DAT`. |
| `--parity-dump=<path>` | yes | Output JSONL. One tick per line. Absolute or CWD-relative. |
| `--parity-ticks=<N>` | yes, N>0 | Number of ticks to simulate after the save loads. Output has N+1 lines (tick 0 = post-load). |
