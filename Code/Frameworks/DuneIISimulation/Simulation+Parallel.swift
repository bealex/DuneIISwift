import Foundation
import Synchronization
import DuneIIContracts
import DuneIIWorld

// MARK: - Experimental intra-tick parallelism (NON-GOLDEN)
//
// This file is the *experiment* behind `Documentation/Architecture/Parallelization.md` §4e — running the
// unit phase across cores within one tick. It is **deliberately non-golden** (the `SPEEDUP_UNORDERED`
// class): it reorders the shared RNG stream and discards cross-shard effects, so its results diverge from
// the sequential/oracle path by design. It exists to *measure* whether intra-tick parallelism pays off for
// this engine (see `Apps/simbench`), not to be a faithful build.
//
// Memory-safety (the one thing that is NOT negotiable, §1): each shard works on its own **value copy** of
// the whole `Simulation` (`Simulation` is `Sendable`; the pools are COW, so the copy is a retain until the
// shard's first write). No two shards touch the same `Array`, so there is no data race — just lost
// cross-shard writes (the accepted approximation). This sidesteps the full deferred-effects refactor
// (§4e.4) that a *correct, within-spread* unordered build would need; for a throughput measurement the
// per-unit compute is identical, which is what we are timing.

extension Simulation {
    /// Parallel variant of `gameLoopUnit` (§4e). Advances the cadence once, partitions the live unit slots
    /// into `shardCount` contiguous chunks, runs each chunk on its own `Simulation` copy via
    /// `DispatchQueue.concurrentPerform` (a parallel-for with a built-in join barrier), then serially merges
    /// each shard's *own* units back. Below `threshold` live units (or `shardCount <= 1`) it falls back to
    /// the sequential body — the §4e.3 small-scenario guard that stops parallelism from being a net loss.
    ///
    /// Approximation (non-golden): cross-shard writes a shard makes onto state it does not own — combat
    /// damage to another shard's unit, spawned projectiles, shared-map claims, house credit deltas — live on
    /// that shard's throwaway copy and are dropped at merge. Per-unit *compute* is identical to sequential,
    /// so the wall-clock comparison is fair; the simulated trajectory is not faithful. See the file header.
    public mutating func gameLoopUnitParallel(shardCount: Int, threshold: Int = 64) {
        let flags = advanceUnitCadence()

        var built: [Int] = []
        var find = PoolFind()
        while let s = state.unitFind(&find) { built.append(s) }
        let slots = built                                     // immutable ⇒ safe to capture concurrently

        let n = slots.count
        let shards = max(1, min(shardCount, n))
        if shards <= 1 || n < threshold {
            runUnitPhase(flags: flags, slots: slots)
            return
        }

        let snapshot = self                                   // immutable per-shard base (COW retain)
        let chunk = (n + shards - 1) / shards
        // Collect each shard's resulting `Simulation` (avoids naming the `Unit` type, which collides with
        // Foundation's `Unit`). One lock-write per shard ⇒ negligible contention.
        let results = Mutex<[Simulation?]>(Array(repeating: nil, count: shards))

        DispatchQueue.concurrentPerform(iterations: shards) { s in
            let lo = s * chunk
            guard lo < n else { return }
            let hi = min(lo + chunk, n)
            var shard = snapshot                              // first write COWs this shard's pools only
            shard.runUnitPhase(flags: flags, slots: Array(slots[lo ..< hi]))
            results.withLock { $0[s] = shard }
        }

        // Merge each shard's *own* slots back (one writer per slot ⇒ deterministic given the partition).
        results.withLock { all in
            for s in 0 ..< shards {
                guard let shard = all[s] else { continue }
                let lo = s * chunk
                if lo >= n { continue }
                let hi = min(lo + chunk, n)
                for i in lo ..< hi { state.units[slots[i]] = shard.state.units[slots[i]] }
            }
        }
    }

    /// Public entry to the sequential unit phase (the internal `gameLoopUnit`), so the benchmark can A/B it
    /// against `gameLoopUnitParallel` on identical inputs.
    public mutating func gameLoopUnitSequential() { gameLoopUnit() }

    /// `tick()` with the unit phase swapped for `gameLoopUnitParallel`. Same four-phase order and the same
    /// (sequential) team/structure/house phases — only the unit phase is parallel. `shardCount == 0` ⇒ use
    /// the active core count. NON-GOLDEN (see file header).
    public mutating func tickParallel(shardCount: Int = 0) {
        state.soundEvents.removeAll(keepingCapacity: true)
        state.pendingFeedback.removeAll(keepingCapacity: true)
        if !state.scenario.spiceFields.isEmpty { applyScenarioSpiceFields() }
        state.timerGUI &+= 1
        if state.paused { return }
        state.timerGame &+= 1

        let shards = shardCount > 0 ? shardCount : ProcessInfo.processInfo.activeProcessorCount
        gameLoopTeam()
        gameLoopUnitParallel(shardCount: shards)
        gameLoopStructure()
        gameLoopHouse()
        evaluateLevelEnd()
        if tickAnimations { state.animationTick() }
        if tickExplosions {
            state.explosionTick()
            drainBloomDetonations()
            drainCraters()
        }
    }
}

// MARK: - Per-phase timing (benchmark instrumentation)

/// Accumulated wall-clock per tick phase, summed over a run. Used by `Apps/simbench` to show *where* the
/// time goes — the prerequisite for judging whether parallelizing any single phase can pay off (Amdahl).
public struct PhaseTimings: Sendable {
    public var team = Duration.zero
    public var unit = Duration.zero
    public var structure = Duration.zero
    public var house = Duration.zero
    public var other = Duration.zero   // clocks + level-end + spice fields + animation/explosion tails
    public var ticks = 0

    public init() {}

    public var total: Duration { team + unit + structure + house + other }
}

extension Simulation {
    /// One instrumented tick that accumulates per-phase durations into `t`. `parallelUnits` swaps the unit
    /// phase for `gameLoopUnitParallel(shardCount:)`. The clock reads bracket each phase; the reads
    /// themselves are a fixed, tiny per-tick overhead applied equally to both modes, so phase *ratios* and
    /// the sequential-vs-parallel unit-phase comparison stay meaningful.
    public mutating func tickTimed(parallelUnits: Bool, shardCount: Int, into t: inout PhaseTimings) {
        let clock = ContinuousClock()
        var mark = clock.now
        func lap() -> Duration { let now = clock.now; defer { mark = now }; return mark.duration(to: now) }

        state.soundEvents.removeAll(keepingCapacity: true)
        state.pendingFeedback.removeAll(keepingCapacity: true)
        if !state.scenario.spiceFields.isEmpty { applyScenarioSpiceFields() }
        state.timerGUI &+= 1
        if state.paused { t.other += lap(); return }
        state.timerGame &+= 1
        t.other += lap()

        gameLoopTeam(); t.team += lap()
        if parallelUnits {
            gameLoopUnitParallel(shardCount: shardCount)
        } else {
            gameLoopUnit()
        }
        t.unit += lap()
        gameLoopStructure(); t.structure += lap()
        gameLoopHouse(); t.house += lap()
        evaluateLevelEnd()
        if tickAnimations { state.animationTick() }
        if tickExplosions {
            state.explosionTick()
            drainBloomDetonations()
            drainCraters()
        }
        t.other += lap()
        t.ticks += 1
    }
}
