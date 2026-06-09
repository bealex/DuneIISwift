# Profiling — heavy-scenario headless tick + render

Two small, **measurement-only** harnesses for "is anything a bottleneck?" — one for the headless simulation
tick, one for the renderer. Both are additive and parity-neutral: the ordinary `tick()` is untouched, the
scenario / RNG-stream / render goldens stay byte-identical, and there is no oracle for wall-clock numbers
(they are machine-dependent), so neither is a golden — they print numbers and assert only loose sanity
bounds. See also `Parallelization.md` (the prior, deeper optimization experiment and its conclusions).

## Headless tick profiler — `duneii-headless profile`

```
swift run -c release duneii-headless profile [SCENARIO.INI] [ticks]
# defaults: SCENH022.INI (the heaviest late-game base), 2000 ticks
```

It loads a real late-game campaign scenario through the **full** live simulation (all six houses, unit +
structure + **team** scripts bridged, every AI house woken at load, animations + explosions on), warms up,
then runs `ticks` profiled ticks and prints a per-phase wall-clock breakdown. Per-phase timing comes from
`Simulation.tickProfiled()` (in `Frameworks/DuneIISimulation/Simulation+Profile.swift`) — the same code path
as `tick()` with each of the four `gameLoop*` phases bracketed by a `ContinuousClock` read; the four
`if profile` branches are predicted-not-taken no-ops in the ordinary `tick()`, so they change no logic, RNG,
or state (the goldens prove it).

### Findings (16-core Apple Silicon, `-c release`, SCENH022 — a built-up Harkonnen base)

```
  scenario SCENH022.INI  units 25  structures 60  AI-active houses 3
  0.0065 ms/tick   ~155k ticks/s
  phase        ms/tick      %
  team         0.0001 ms    1.0%
  unit         0.0046 ms   70.5%   ← dominant
  structure    0.0014 ms   22.2%
  house        0.0001 ms    2.3%
  other        0.0003 ms    3.9%   (animation + explosion tail; off the parity path)
  peak entities: units 46, structures 60, bullets 1
```

**Conclusion: the headless tick is not a bottleneck** — ~155k ticks/s at faithful scale (46 units / 60
structures, the realistic ceiling for the 102-slot, type-partitioned faithful pool). The **unit phase
dominates (~70%)**, structures ~22%, team/house negligible — consistent with the `Parallelization.md` §8.2
measurement. No new hotspot surfaced; the single-thread allocation/ARC work in `Parallelization.md` §8.5
already removed the per-tick allocation churn, and the sequential tick remains faster than every parallel
variant measured there. If a future workload needs more, the levers are (in order) §3 single-thread micro-opts
→ §4a many independent sims in parallel — **not** threading one tick.

## Render profiler — `RenderProfilingTests`

```
swift test --filter RenderProfilingTests
```

Loads a heavy frame (SCENH022, full 64×64 map, fog on, advanced 200 ticks) through the real sim + real
`SpriteKitRenderer`, and times the three per-frame stages separately. Skips (passes) when the install is
absent or no off-screen GPU context exists, like the render goldens.

### Findings (debug test build — relative magnitudes are the point)

| Stage | ms/frame | Notes |
|---|---|---|
| `makeFrameInfo()` | ~0.5 | pure `GameState → FrameInfo` CPU read; cheap |
| `render()` (live) | ~0.6 (~1800 fps) | the on-screen per-frame node/texture/palette update — **not a bottleneck** |
| `snapshot()` (capture) | ~84 | `render()` **plus** a full-map GPU→CPU `texture(from:)` read-back + `CGImage` |

**Conclusion: the live render path is not a bottleneck** (~1800 fps headroom on a full map). The only
expensive render op is `snapshot()`, and its cost is **entirely the GPU→CPU read-back** of a full ~1024×1024
retina image — paid only by the **capture** path (render goldens, `rendercap`), never by gameplay. So a slow
golden capture is expected and is not the live frame cost. If capture throughput ever matters (bulk reference
regeneration), the lever is the read-back/crop, not the node build.
