# Tick-parity golden harness

Closes §6 of `Documentation/Plans/01.Initial.md`: a CI-grade diff between OpenDUNE's per-tick simulation state and ours. The harness captures OpenDUNE's full pool state once per tick across N ticks, replays the same starting state through our `Simulation.Scheduler.tick()`, and asserts every field of every slot matches on every tick.

When a divergence appears, the harness stops at the first bad tick and reports `(tick, poolKind, slot, field, expected, actual)` so a single line pins the drift.

## Starting state: load a save, don't start a scenario

The obvious question is "how do you run a scenario with no user input when the only thing built at scenario start is a construction yard?" The answer: we don't start from scenario INI — we **start from a save file**.

Both engines already load `_SAVE00?.DAT` natively. Our path is `Simulation.WorldSnapshot.init(save:)`; OpenDUNE's is `LoadGame_LoadFromFile`. Picking a mid-mission save gives us a starting state where the refinery + windtrap + harvester are already placed and the harvest loop is running — so "no user input" is fine, because the script VM keeps the sim alive on its own (harvester loops, team AI sends hunters, spice depletes, turrets fire).

Different saves exercise different slices of sim behaviour:

| Save | Exercises |
|---|---|
| `_SAVE001.DAT` (mission 1 mid-game) | Harvest loop, team AI pathing, spice depletion, IdleAction RNG |
| combat-heavy save (TBD) | Fire gate, bullet flight, explosion radius damage, `explodeOnDeath` |
| factory-busy save (TBD) | Construction countdown, credit drain, factory spawn |

First-cut harness runs only the mid-game save. The others land as drift appears in later sessions.

### Why not scripted input?

An alternative is to inject clicks/keystrokes at fixed ticks into both engines. Rejected: OpenDUNE's input path goes through SDL events and GUI widget trees that are a nightmare to synthesise headlessly, and the harness is about **tick parity**, not **input parity**. Anything that requires clicking to exercise is outside this harness's scope — for those, a scripted Swift-side test drives `ScenarioRuntime` directly.

## Capture side: patch OpenDUNE

The capture must run **fully headless** (no display, no audio) and **as fast as the CPU allows** — not at OpenDUNE's real-time 60 Hz. A golden recording of 200 ticks should finish in well under a second and produce bit-identical output on any machine regardless of GUI session or audio hardware.

### CLI flags (all added by the patch)

| Flag | Effect |
|---|---|
| `--parity-load=<save>` | Skip the menu. Immediately call `LoadGame_LoadFromFile(save)` and enter the scenario at the save state. |
| `--parity-ticks=<N>` | After load, run exactly N ticks in deterministic step mode, then exit 0. Implies `--parity-dump` is required. |
| `--parity-dump=<path>` | Destination for the per-tick `.jsonl` file. Appended one line per tick. |

When any `--parity-*` flag is present, the patch flips a single `g_parityMode` bool that gates every piece of headless / fast-forward behaviour described below. Without the flag, OpenDUNE behaves exactly as vanilla.

### Headless requirements

1. **Dummy video backend.** Before `Video_Init` is called, the patch calls `SDL_setenv("SDL_VIDEODRIVER", "dummy", 1)`. SDL's built-in dummy driver satisfies the full video API — `SDL_Init(SDL_INIT_VIDEO)`, `SDL_CreateWindow`, surface allocation — without opening a window or requiring a display server. This works on CI boxes with no X11 and on macOS without a logged-in console session.

2. **Skip audio init.** `--parity-mode` short-circuits `Music_InitMT32`, `Driver_Voice_Play`, and the XMI mixer callbacks to no-ops. Audio state doesn't affect pool parity, and initialising a real audio device on headless CI is flaky.

3. **No input polling.** The parity-mode main loop does not call `GUI_Widget_HandleEvents` or any input driver. The scenario runs entirely from its own scripts — no mouse, no keyboard, no widget tree.

4. **No real-time timer callbacks.** `Timer_Init` is *not* called in parity mode. In vanilla, `Timer_Init` registers a `SIGALRM` handler at 1000000/60 µs that increments `g_timerGame` / `g_timerGUI` in the background; in parity mode these globals are advanced manually from the main loop (see below) so behaviour is deterministic and not at the mercy of signal-delivery jitter.

### Deterministic fast-forward loop

In parity mode, `GameLoop_Main`'s `for (;; sleepIdle())` is replaced with a counted, tight-loop variant. Pseudocode:

```c
if (g_parityMode) {
    LoadGame_LoadFromFile(g_parityLoadPath);
    FILE *dump = fopen(g_parityDumpPath, "w");
    ParityDump_Write(dump, g_timerGame);   // tick 0 = post-load, pre-first-tick
    for (uint32 t = 1; t <= g_parityTicks; t++) {
        g_timerGame++;                     // manual tick advance (no signal)
        g_timerGUI++;
        GameLoop_Unit();                   // run the same per-tick work the
        GameLoop_Structure();              //   60 Hz timer would trigger
        GameLoop_Team();
        GameLoop_House();
        ParityDump_Write(dump, t);
    }
    fclose(dump);
    exit(0);
}
```

This gets us three things vanilla can't: every tick is a pure function of the prior tick (signal jitter eliminated), the loop runs as fast as the CPU executes it (200 ticks finish in tens of milliseconds, not ~3.3 seconds), and there is exactly one place in the binary that emits a golden line — `ParityDump_Write`, right after the per-tick work. That single-emission site is the thing we compare our `Scheduler.tick()` output against.

The patch lives under `Repositories/OpenDUNE/` applied on top of vanilla OpenDUNE. Because `Repositories/OpenDUNE` is a read-only reference in our repo, the patch is delivered as a single `tick_parity_dump.patch` file at `Documentation/Architecture/opendune-parity-patch/` that the developer applies manually:

```
cd Repositories/OpenDUNE
git apply ../../Documentation/Architecture/opendune-parity-patch/tick_parity_dump.patch
make -j
./bin/opendune --parity-load=_SAVE001.DAT --parity-ticks=200 --parity-dump=/tmp/golden.jsonl
# no display required, no audio touched, completes in <1 s
```

The resulting `/tmp/golden.jsonl` is dropped into `Code/Core/Tests/DuneIICoreTests/Fixtures/ParityGoldens/save001_200ticks.jsonl` for the parity tests to read. The fixtures under `ParityGoldens/*.jsonl` are **gitignored — not committed**: regenerate them locally from OpenDUNE whenever you need them. Tests short-circuit (no-op return) when the golden is missing, so a fresh checkout still builds and the rest of the suite stays green.

We do **not** vendor a pre-built OpenDUNE binary either. Anyone regenerating a fixture builds the patched OpenDUNE locally and runs it. The OpenDUNE source + parity patch is the ground truth; the JSONL files are just a cache of its output.

### What the patch must NOT change

Tick-parity is only meaningful if the patched OpenDUNE's sim is bit-identical to vanilla's. The patch must not:

- Modify any of `src/unit.c`, `src/structure.c`, `src/team.c`, `src/house.c`, `src/script/*`, `src/map.c`, `src/pool/*`, `src/tools.c`, or any file under `src/table/`.
- Change when `g_timerGame` / `g_timerGUI` are read — only *where* they're incremented.
- Alter RNG seeding (`Tools_Random_Seed`, LCG init). The save file's seed is authoritative.
- Run any additional frames of logic. Exactly one `GameLoop_*` pass per `--parity-ticks` increment.

If a divergence turns up that could be blamed on the patch, it isn't the patch's job to hide it. Emit the dump and let the harness flag it.

## State schema

One JSON object per tick, one tick per line. Minimal field set for the first run — widen only when a divergence demands it.

```json
{
  "tick": 42,
  "rng": { "lcg": 1234567890, "tools": [12, 34, 56, 78] },
  "houses": [
    { "index": 0, "credits": 987, "creditsStorage": 2000, "creditsQuota": 0 }
  ],
  "units": [
    {
      "index": 22, "type": 16, "houseID": 0,
      "positionX": 5632, "positionY": 4864,
      "hitpoints": 200, "actionID": 8, "orientationCurrent": 64,
      "movingSpeed": 128, "speed": 2, "speedPerTick": 240, "speedRemainder": 16,
      "amount": 50, "linkedID": 255, "inTransport": false,
      "targetMove": 16512, "targetAttack": 0, "currentDestX": 5648, "currentDestY": 4864,
      "route0": 2, "route1": 6, "route2": 255,
      "spriteOffset": 0, "fireDelay": 0
    }
  ],
  "structures": [
    { "index": 0, "type": 1, "houseID": 0, "hitpoints": 600, "state": 0, "countDown": 0, "linkedID": 255 }
  ]
}
```

**Minimal, not maximal.** Bullets (types 18..24) are captured in the `units` array but can be excluded via a `--parity-skip-bullets` flag until bullet-script parity lands (bullets currently detonate via scheduler shortcut, not `BULLET.EMC`). Explosions, fog, and selection state are out of scope for v1.

Field ordering in the unit/structure arrays is **pool-index-ascending**, not find-array-ascending. The `Scheduler.tick()` walk order is already find-array-ascending, but the dump is a snapshot of slot state at tick boundary, so pool-index ordering is stable and unambiguous.

## Replay side: `ParityHarness` in Swift

New module under `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift`:

```swift
public enum ParityHarness {
    public struct Divergence: Error, CustomStringConvertible {
        public let tick: Int
        public let kind: String     // "unit" / "structure" / "house" / "rng"
        public let slot: Int
        public let field: String
        public let expected: String
        public let actual: String
    }

    public static func runAgainst(
        save: Data,
        golden: Data,
        tickLimit: Int
    ) throws
}
```

Flow:

1. Decode golden as newline-delimited JSON into `[GoldenTick]`.
2. Build our `WorldSnapshot.init(save:)` from the same save bytes. Seed `Scheduler.rngLCG` + `Scheduler.toolsRandom` from `goldenTicks[0].rng` (tick 0 = post-load, pre-first-tick).
3. For `t in 1...min(tickLimit, goldenTicks.count - 1)`:
   - Call `scheduler.tick()`.
   - Diff every captured field slot-by-slot against `goldenTicks[t]`.
   - First mismatch → throw `Divergence` and stop.

A test in `Core/Tests/DuneIICoreTests/ParityHarnessTests.swift` gates on `TestInstall.locate()` (the save lives under `Repositories/patched_107_unofficial/` which is read-only and install-gated) and on the presence of the committed golden fixture.

## Known gaps the harness will surface (allow-list empty at v1)

The harness is expected to diverge immediately on several known-simplified code paths. These go in an allow-list at `ParityHarness.allowedDivergences` so the first run is useful instead of a wall of expected failures:

- `spriteOffset` on IdleAction (our RNG path matches, but the SHP-animation offset increments differently — cosmetic).
- `fireDelay` modifier via `Tools_Random_256` jitter (we don't apply the jitter — see `Documentation/Algorithms/Fire.md`).
- Voice / fog side-effects (we skip these entirely).

The allow-list starts **empty** so we see every gap, then we widen it explicitly as we close or document each one. Each allow-list entry cites the file:line of the deliberate simplification in our code.

## Scope creep guardrails

This harness does **not**:

- Attempt visual parity. Pixel-level rendering is a separate concern.
- Attempt save-file-write parity. Our save-chunk writers land in P6.
- Attempt input parity. Scripted tests on `ScenarioRuntime` cover click flows.
- Attempt real-time timing parity. We tick synchronously — both engines run in "advance one logical tick" mode, not wall-clock.

## How it runs in CI

A single SwiftTesting test case:

```swift
@Test("Tick parity: _SAVE001.DAT for 200 ticks")
func saveOneParity() throws {
    guard let installRoot = TestInstall.locate() else { return }
    let save = try Data(contentsOf: installRoot.appending(path: "_SAVE001.DAT"))
    let goldenURL = Bundle.module.url(forResource: "save001_200ticks", withExtension: "jsonl")!
    let golden = try Data(contentsOf: goldenURL)
    try ParityHarness.runAgainst(save: save, golden: golden, tickLimit: 200)
}
```

Green = byte-identical sim for 200 ticks. Red = a `Divergence` message pointing at the exact field.

## Implementation order (expected to span multiple sessions)

1. **`Unit_SetSpeed` gameSpeed pipeline.** Before the harness is useful, we must match OpenDUNE's `Tools_AdjustToGameSpeed` + winger bypass. Without this, any tick after a unit moves will diverge on `speed` / `speedPerTick`. (This session.)
2. **OpenDUNE patch + golden capture.** One-time C work. Output committed as fixture.
3. **`ParityHarness` skeleton + first `runAgainst` call.** Expected to diverge within the first handful of ticks.
4. **Close divergences one by one**, in order of first-tick-seen. Each closure is a normal feature: OpenDUNE citation, Swift change, test, history entry, update this doc's allow-list.

## References

- OpenDUNE tick entry points: `src/unit.c:123 GameLoop_Unit`, `src/structure.c GameLoop_Structure`, `src/opendune.c:905 GameLoop_Main`.
- `Tools_AdjustToGameSpeed`: `src/tools.c:20`.
- `Unit_SetSpeed`: `src/unit.c:1902`.
- Per-tick subpixel accumulator: `src/unit.c:98 Unit_MovementTick`.
- Save loader: `src/saveload/savegame.c LoadGame_LoadFromFile`.
- Real-time timer that we replace with manual stepping: `src/timer.c:361 Timer_Tick` (registered via `Timer_Add` at 1000000/60 µs).
- SDL dummy video backend (set via `SDL_setenv("SDL_VIDEODRIVER", "dummy", 1)` before `Video_Init`): documented at `https://wiki.libsdl.org/SDL2/FAQUsingSDL#how_do_i_use_sdl_on_a_system_without_a_display`.
