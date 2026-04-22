import Foundation
import Memoirs

extension Simulation {
    /// Per-tick driver for EMC script dispatch. Walks the unit and
    /// structure pools on each `tick()` call; for each allocated slot,
    /// either decrements the engine's `delay` or runs up to the category
    /// opcode budget via `VM.step(_:)`.
    ///
    /// Mirrors the `tickScript` block of OpenDUNE's `Unit_Tick` /
    /// `Structure_Tick`. See `Documentation/Algorithms/TickScheduler.md`.
    public struct Scheduler {
        public let host: Scripting.Host
        public let unitVM: Scripting.VM
        public let structureVM: Scripting.VM
        public let teamVM: Scripting.VM

        /// Per-slot engines. Indexed by pool slot index; the engine at
        /// `unitEngines[n]` belongs to `host.units[n]`.
        public var unitEngines: [Scripting.Engine]
        public var structureEngines: [Scripting.Engine]
        public var teamEngines: [Scripting.Engine]

        /// Tracks the action / type / action each engine was last
        /// `VM.load(engine:typeID:)`-ed with. OpenDUNE's `Script_Load`
        /// runs once per action change; we mirror that by detecting the
        /// delta here. `-1` means "engine is fresh, reload needed".
        private var loadedUnitAction: [Int]
        private var loadedStructureType: [Int]
        private var loadedTeamAction: [Int]

        public static let unitOpcodesPerTick = 7
        public static let structureOpcodesPerTick = 3
        public static let teamOpcodesPerTick = 5
        /// One harvest / refine call every N scheduler ticks. Our tick
        /// rate is ~12 Hz; OpenDUNE's `Script_Unit_Harvest` runs with
        /// `script.delay = 6` at a ~30 Hz cadence (~200 ms between
        /// calls), so 3 of our ticks (~250 ms) matches reasonably.
        public static let harvestCadenceTicks = 3

        /// Optional `Tools_Random_256` source used by the harvesting
        /// pass. `nil` disables the pass even when `host.spiceMap` is
        /// set — tests that don't need harvest can skip wiring it.
        public let harvestRNG: (() -> UInt8)?
        private var harvestTickCounter: Int = 0

        /// Structure type IDs that have no script and are skipped during
        /// dispatch. Mirrors OpenDUNE's `STRUCTURE_SLAB_1x1`,
        /// `STRUCTURE_SLAB_2x2`, `STRUCTURE_WALL`.
        public static let skippedStructureTypes: Set<UInt8> = [0, 1, 14]

        /// Types 18..24 are projectiles — MISSILE_*, BULLET, SONIC_BLAST.
        /// They detonate on arrival at `currentDestination` rather than
        /// resuming along a route. Matches OpenDUNE's `flags.isBullet`
        /// group in `UnitInfo`.
        static func isProjectileType(_ type: UInt8) -> Bool {
            return (18...24).contains(type)
        }

        /// True when ground units of `movementType` can traverse the
        /// tile at `(tileX, tileY)`. Combines:
        ///
        /// - Live structure-pool check: any structure's footprint is
        ///   impassable regardless of landscape (walls, refineries,
        ///   windtraps). Needed because the baseline `landscapeAt`
        ///   closure is a snapshot and doesn't reflect runtime-placed
        ///   buildings.
        /// - `LandscapeInfo.movementSpeed[movementType] != 0` via the
        ///   host's `landscapeAt` closure. Baseline rock / mountain
        ///   gating.
        ///
        /// Winger (air) and slither (sandworm) always pass. Off-map
        /// tiles are never passable.
        func isTilePassable(
            tileX: Int, tileY: Int, movementType: MovementType
        ) -> Bool {
            if movementType == .winger || movementType == .slither { return true }
            guard (0..<64).contains(tileX), (0..<64).contains(tileY) else { return false }
            for idx in host.structures.findArray {
                let s = host.structures.slots[idx]
                let ax = Int(s.positionX) / 256
                let ay = Int(s.positionY) / 256
                let footprint = Structures.footprintTiles(type: s.type, anchorX: ax, anchorY: ay)
                if footprint.contains(where: { $0.0 == tileX && $0.1 == tileY }) {
                    return false
                }
            }
            guard let lookup = host.landscapeAt else { return true }
            let packed = UInt16(tileY * 64 + tileX)
            let raw = lookup(packed)
            guard let landscape = LandscapeType(rawValue: Int(raw)) else { return true }
            let info = LandscapeInfo.lookup(landscape)
            let mt = Int(movementType.rawValue)
            guard mt < info.movementSpeed.count else { return true }
            return info.movementSpeed[mt] != 0
        }

        /// Slice 6b helper. Nearest same-house REFINERY for a full
        /// harvester. Uses squared-distance over the structure anchor
        /// tiles (close enough for routing; route cost lives in the
        /// pathfinder). Returns `nil` when the house owns no refinery.
        static func findNearestRefinery(
            forHarvester harvester: UnitSlot,
            structures: StructurePool
        ) -> Int? {
            let hx = Int(harvester.positionX) / 256
            let hy = Int(harvester.positionY) / 256
            var bestIdx: Int?
            var bestDist = Int.max
            for idx in structures.findArray {
                let s = structures.slots[idx]
                guard s.type == 12 /* REFINERY */ else { continue }
                guard s.houseID == harvester.houseID else { continue }
                let sx = Int(s.positionX) / 256
                let sy = Int(s.positionY) / 256
                let dx = sx - hx
                let dy = sy - hy
                let d = dx * dx + dy * dy
                if d < bestDist {
                    bestDist = d
                    bestIdx = idx
                }
            }
            return bestIdx
        }

        /// Slice 6b helper. Returns the refinery pool index whose 3×2
        /// footprint covers `tile` and belongs to `houseID`, else nil.
        static func refineryAt(
            tile: (x: Int, y: Int),
            houseID: UInt8,
            structures: StructurePool
        ) -> Int? {
            for idx in structures.findArray {
                let s = structures.slots[idx]
                guard s.type == 12 else { continue }
                guard s.houseID == houseID else { continue }
                let ax = Int(s.positionX) / 256
                let ay = Int(s.positionY) / 256
                for (fx, fy) in Structures.footprintTiles(
                    type: s.type, anchorX: ax, anchorY: ay
                ) where fx == tile.x && fy == tile.y {
                    return idx
                }
            }
            return nil
        }

        public init(
            host: Scripting.Host,
            unitVM: Scripting.VM,
            structureVM: Scripting.VM,
            teamVM: Scripting.VM? = nil,
            harvestRNG: (() -> UInt8)? = nil
        ) {
            self.host = host
            self.unitVM = unitVM
            self.structureVM = structureVM
            self.harvestRNG = harvestRNG
            // Default teamVM: reuses the unit program (empty / halted) so
            // the scheduler's team-tick is a safe no-op when no TEAM.EMC
            // is supplied. Callers that load the real TEAM.EMC pass it
            // explicitly.
            self.teamVM = teamVM ?? unitVM
            self.unitEngines = Array(
                repeating: Scripting.Engine.reset(),
                count: Simulation.UnitPool.capacity
            )
            self.structureEngines = Array(
                repeating: Scripting.Engine.reset(),
                count: Simulation.StructurePool.capacityHard
            )
            self.teamEngines = Array(
                repeating: Scripting.Engine.reset(),
                count: Simulation.TeamPool.capacity
            )
            self.loadedUnitAction = Array(repeating: -1, count: Simulation.UnitPool.capacity)
            self.loadedStructureType = Array(repeating: -1, count: Simulation.StructurePool.capacityHard)
            self.loadedTeamAction = Array(repeating: -1, count: Simulation.TeamPool.capacity)
        }

        public mutating func tick() {
            // Fire-cooldown decrement runs first. `Script_Unit_Fire`
            // reads `fireDelay == 0` as its gate; decrementing before
            // the EMC dispatch matches OpenDUNE's `Unit_Tick` order.
            tickFireCooldowns()
            // Explosion frame decrement — simple lifetime tick for the
            // presentation layer. Matches OpenDUNE's `Explosion_Tick`
            // reducing each active slot's `timeOut`, but simplified to
            // a single frame counter since we don't run the command
            // stream yet.
            tickExplosions()
            // Route-follower runs BEFORE script dispatch so scripts (e.g.
            // `CalculateRoute`) observe the updated position when deciding
            // whether to pop the next step or re-plan.
            tickMovement()
            // Construction countdown + credit drain pass. Drains
            // `countDown` on BUSY yards (paused when the owning house
            // can't pay the per-tick cost) and flips to `READY` at
            // zero. Port of the relevant section of OpenDUNE's
            // `GameLoop_Structure`. Slice 4d-sim + 6b.
            Simulation.Structures.tickConstruction(
                pool: &host.structures, houses: &host.houses
            )
            // Units first, then structures, then teams — matches OpenDUNE's
            // main loop in `Server_Main.c`.
            tickUnits()
            tickStructures()
            tickTeams()
            // Harvest / refine runs after unit & structure ticks so the
            // script-driven action / linkedID state is settled for the
            // current tick. Gated on both a non-nil spiceMap (so tests
            // can skip) and an RNG closure (Tools_Random_256 port).
            harvestTickCounter &+= 1
            if host.spiceMap != nil, harvestRNG != nil,
               harvestTickCounter % Self.harvestCadenceTicks == 0
            {
                tickHarvesting()
            }
            host.currentObject = nil
        }

        /// One harvest / refine pass. Iterates:
        /// - Every HARVESTER in ACTION_HARVEST with `inTransport=false`
        ///   (not yet docked) — calls `Units.harvestSpiceStep` using
        ///   `host.spiceMap` as the landscape reader + level writer.
        /// - Every REFINERY with `linkedID != 0xFF` (docked harvester)
        ///   — calls `Structures.refineSpiceStep` once per pass.
        ///
        /// Logs entry + per-pool-entry activity under the `harvest-tick`
        /// tracer so traces tell the full harvesting story.
        public mutating func tickHarvesting() {
            guard var spiceMap = host.spiceMap else { return }
            guard let rng = harvestRNG else { return }
            let playerHouse = host.playerHouseID ?? 0
            var harvestedCount = 0
            var refinedPairs = 0

            // Harvester AI transitions (slice 6b):
            // - HARVEST + amount>=100 + not docked → seek nearest
            //   same-house refinery, issue move, flip to RETURN.
            // - RETURN + on a refinery footprint → dockHarvester,
            //   flip back to HARVEST.
            for idx in host.units.findArray {
                let slot = host.units.slots[idx]
                guard slot.type == 16 else { continue }
                if slot.actionID == Simulation.ActionID.harvest,
                   slot.amount >= 100, !slot.inTransport
                {
                    if let refIdx = Self.findNearestRefinery(
                        forHarvester: slot, structures: host.structures
                    ) {
                        let r = host.structures.slots[refIdx]
                        let rx = Int(r.positionX) / 256
                        let ry = Int(r.positionY) / 256
                        _ = Simulation.Units.orderMove(
                            poolIndex: idx, tileX: rx, tileY: ry, units: &host.units
                        )
                        var u = host.units[idx]
                        u.actionID = Simulation.ActionID.returnAction
                        host.units[idx] = u
                        Log.info(
                            "harvest-cycle full harvester=\(idx) → refinery=\(refIdx) tile=(\(rx),\(ry))",
                            tracer: .label("harvest-tick")
                        )
                    }
                } else if slot.actionID == Simulation.ActionID.returnAction,
                          !slot.inTransport
                {
                    let tx = Int(slot.positionX) / 256
                    let ty = Int(slot.positionY) / 256
                    if let refIdx = Self.refineryAt(
                        tile: (x: tx, y: ty), houseID: slot.houseID,
                        structures: host.structures
                    ) {
                        _ = Simulation.Structures.dockHarvester(
                            refineryIndex: refIdx, harvesterIndex: idx,
                            structures: &host.structures, units: &host.units
                        )
                        // After dock, flip action back to HARVEST so
                        // the post-undock path resumes seeking spice
                        // without needing a fresh AI pass.
                        var u = host.units[idx]
                        u.actionID = Simulation.ActionID.harvest
                        host.units[idx] = u
                        Log.info(
                            "harvest-cycle arrived harvester=\(idx) refinery=\(refIdx) DOCK",
                            tracer: .label("harvest-tick")
                        )
                    }
                }
            }

            // Harvest pass.
            for idx in host.units.findArray {
                let slot = host.units.slots[idx]
                guard slot.type == 16 /* HARVESTER */ else { continue }
                guard slot.actionID == Simulation.ActionID.harvest else { continue }
                guard !slot.inTransport else { continue }
                let before = slot.amount
                _ = Simulation.Units.harvestSpiceStep(
                    harvesterIndex: idx,
                    units: &host.units,
                    landscapeAt: { spiceMap.landscapeByte(at: $0) },
                    changeSpice: { packed, delta in spiceMap.apply(delta: delta, at: packed) },
                    rng: rng
                )
                if host.units.slots[idx].amount != before { harvestedCount += 1 }
            }

            // Refine pass.
            var undockedThisPass: [(refineryIdx: Int, harvesterIdx: Int)] = []
            for idx in host.structures.findArray {
                let refinery = host.structures.slots[idx]
                guard refinery.type == 12 /* REFINERY */ else { continue }
                guard refinery.linkedID != 0xFF else { continue }
                let harvIdx = Int(refinery.linkedID)
                _ = Simulation.Structures.refineSpiceStep(
                    refineryIndex: idx,
                    harvesterIndex: harvIdx,
                    structures: host.structures,
                    units: &host.units,
                    houses: &host.houses,
                    playerHouseID: playerHouse
                )
                refinedPairs += 1
                // Slice 6a: auto-undock when the refine cycle finishes
                // (amount drained to 0 clears inTransport). Mirrors what
                // a fully-wired `Script_Structure_FindAndLeaveUnit` will
                // drive once the refinery EMC runs; until then we kick
                // the harvester free here so it can re-enter the cycle.
                let finished = !host.units.slots[harvIdx].inTransport
                    && host.units.slots[harvIdx].amount == 0
                if finished {
                    undockedThisPass.append((idx, harvIdx))
                }
            }

            // Undock-after-refine — run in a second pass to avoid
            // mutating the findArray while iterating it. Exit tile is
            // the factorySpawnTile heuristic (south of the footprint).
            for pair in undockedThisPass {
                let refinery = host.structures.slots[pair.refineryIdx]
                let ax = Int(refinery.positionX) / 256
                let ay = Int(refinery.positionY) / 256
                let exit = Simulation.Structures.factorySpawnTile(
                    yardType: refinery.type, anchorX: ax, anchorY: ay
                )
                let released = Simulation.Structures.undockHarvester(
                    refineryIndex: pair.refineryIdx,
                    exitTile: (x: exit.x, y: exit.y),
                    structures: &host.structures,
                    units: &host.units
                )
                if released != nil {
                    // Keep the harvester in HARVEST action so the next
                    // tick's harvest pass picks it up (scene-side AI
                    // slice 6b will reroute to spice before then).
                    var u = host.units[pair.harvesterIdx]
                    u.actionID = Simulation.ActionID.harvest
                    host.units[pair.harvesterIdx] = u
                    Log.info(
                        "harvest-cycle refinery=\(pair.refineryIdx) released harvester=\(pair.harvesterIdx) action=HARVEST tile=(\(exit.x),\(exit.y))",
                        tracer: .label("harvest-tick")
                    )
                }
            }

            // Flush the mutated SpiceMap back into the host.
            host.spiceMap = spiceMap

            if harvestedCount > 0 || refinedPairs > 0 {
                Log.debug(
                    "harvest-tick counter=\(harvestTickCounter) harvested=\(harvestedCount) refined=\(refinedPairs)",
                    tracer: .label("harvest-tick")
                )
            }
        }

        /// Decrements every allocated unit's `fireDelay` by 1 if non-zero.
        /// Mirrors OpenDUNE `Unit_Tick`'s `if (u->fireDelay != 0) u->fireDelay--`.
        private mutating func tickFireCooldowns() {
            for idx in host.units.findArray {
                var slot = host.units.slots[idx]
                if slot.fireDelay != 0 {
                    slot.fireDelay &-= 1
                    host.units[idx] = slot
                }
            }
        }

        /// Decrements every active explosion's `remainingFrames` by 1.
        /// When it reaches 0, frees the slot so the scene-renderer can
        /// observe the disappearance.
        private mutating func tickExplosions() {
            for i in 0..<host.explosions.slots.count where host.explosions.slots[i].isActive {
                var slot = host.explosions.slots[i]
                if slot.remainingFrames <= 1 {
                    host.explosions.free(at: i)
                } else {
                    slot.remainingFrames &-= 1
                    host.explosions[i] = slot
                }
            }
        }

        /// Per-tick route follower. Uses `currentDestination` (pos32)
        /// as the stable per-step target so sub-goals don't shift when
        /// the unit crosses tile boundaries mid-step. Per step:
        ///
        /// 1. If `currentDestination == 0` but `route[0] != 0xFF`, set
        ///    `currentDestination` to the pos32 centre of the tile the
        ///    route step points at (computed from the unit's CURRENT
        ///    tile, i.e. the tile it hasn't left yet).
        /// 2. If `currentDestination == 0` but `targetMove != 0`, slide
        ///    straight toward `targetMove` (no pathfinding — fallback
        ///    for `SetDestinationDirect` and simple `SetDestination`
        ///    calls without a `CalculateRoute` pair).
        /// 3. Step toward `currentDestination`. On arrival (manhattan ≤
        ///    threshold), snap, pop `route[0]`, and clear the destination
        ///    so the next tick picks up the next step.
        private mutating func tickMovement() {
            let arrivalThreshold: Int32 = 16
            for idx in host.units.findArray {
                var slot = host.units.slots[idx]
                let hasDestination = slot.currentDestinationX != 0 || slot.currentDestinationY != 0
                let hasRoute = slot.route[0] != 0xFF
                let hasTargetMove = slot.targetMove != 0

                if !hasDestination && !hasRoute && !hasTargetMove { continue }

                // Populate `currentDestination` from the next route step.
                if !hasDestination, hasRoute {
                    let delta = Pathfinder.mapDirection[Int(slot.route[0])]
                    let currentPacked = Pathfinder.packedTile(x: slot.positionX, y: slot.positionY)
                    let nextPacked = UInt16(truncatingIfNeeded: Int32(currentPacked) + delta)
                    let tileX = Int(nextPacked & 0x3F)
                    let tileY = Int((nextPacked >> 6) & 0x3F)
                    // Defensive: re-check that the tile is still
                    // passable for this unit's movement type. A
                    // structure may have landed on the planned route
                    // since the pathfinder ran, or the route itself
                    // may have been stamped by a non-validating path.
                    let mt = Simulation.UnitInfo.lookup(slot.type)?.movementType ?? .foot
                    if !Self.isProjectileType(slot.type),
                       !isTilePassable(tileX: tileX, tileY: tileY, movementType: mt)
                    {
                        Log.info(
                            "move-halt u\(idx) impassable tile=(\(tileX),\(tileY)) mt=\(mt) — clearing route + target",
                            tracer: .label("move")
                        )
                        slot.route = [UInt8](repeating: 0xFF, count: 14)
                        slot.currentDestinationX = 0
                        slot.currentDestinationY = 0
                        slot.targetMove = 0
                        host.units[idx] = slot
                        continue
                    }
                    slot.currentDestinationX = UInt16(tileX) &* 256 &+ 128
                    slot.currentDestinationY = UInt16(tileY) &* 256 &+ 128
                    Log.debug(
                        "move-step u\(idx) picked route[0]=\(slot.route[0]) → dest=(\(tileX),\(tileY))",
                        tracer: .label("move")
                    )
                }

                // Pick the goal. Route-backed destination wins; else fall
                // back to the targetMove tile directly.
                let goal: Pos32
                let goalSource: String
                if slot.currentDestinationX != 0 || slot.currentDestinationY != 0 {
                    goal = Pos32(x: slot.currentDestinationX, y: slot.currentDestinationY)
                    goalSource = "route"
                } else if let t = Pos32.of(Scripting.EncodedIndex(raw: slot.targetMove), host: host) {
                    // Fallback slide toward a raw targetMove tile. This
                    // bypasses the pathfinder, so guard against walking
                    // straight into an impassable tile (rock for
                    // non-tracked, walls, structures).
                    let goalTileX = Int(t.x) / 256
                    let goalTileY = Int(t.y) / 256
                    let mt = Simulation.UnitInfo.lookup(slot.type)?.movementType ?? .foot
                    if !Self.isProjectileType(slot.type),
                       !isTilePassable(tileX: goalTileX, tileY: goalTileY, movementType: mt)
                    {
                        Log.info(
                            "move-halt u\(idx) fallback target=(\(goalTileX),\(goalTileY)) impassable mt=\(mt) — clearing",
                            tracer: .label("move")
                        )
                        slot.targetMove = 0
                        host.units[idx] = slot
                        continue
                    }
                    goal = t
                    goalSource = "targetMove(fallback)"
                } else {
                    Log.debug(
                        "move-abort u\(idx) targetMove=\(String(format: "0x%04X", slot.targetMove)) invalid; clearing",
                        tracer: .label("move")
                    )
                    slot.targetMove = 0
                    host.units[idx] = slot
                    continue
                }

                let dx = Int32(goal.x) - Int32(slot.positionX)
                let dy = Int32(goal.y) - Int32(slot.positionY)
                let manhattan = abs(dx) + abs(dy)

                if manhattan <= arrivalThreshold {
                    slot.positionX = goal.x
                    slot.positionY = goal.y
                    // Bullet / missile arrival → detonate and free.
                    // OpenDUNE drives this via `BULLET.EMC` calling
                    // `Script_Unit_ExplosionSingle`; we shortcut in the
                    // scheduler until bullet scripts are wired.
                    if Self.isProjectileType(slot.type) {
                        let explosionType = Simulation.UnitInfo.lookup(slot.type)?.explosionType
                            ?? Simulation.ExplosionType.invalid
                        let damage = slot.hitpoints
                        let origin = slot.originEncoded
                        Log.info(
                            "bullet \(idx) (type \(slot.type)) arrived, spawning explosion type=\(explosionType) dmg=\(damage)",
                            tracer: .label("scheduler")
                        )
                        host.units.free(at: idx)
                        Simulation.Explosions.makeExplosion(
                            type: explosionType,
                            position: goal,
                            hitpoints: damage,
                            unitOriginEncoded: origin,
                            host: host
                        )
                        continue
                    }
                    let wasRouteStep = slot.currentDestinationX != 0 || slot.currentDestinationY != 0
                    slot.currentDestinationX = 0
                    slot.currentDestinationY = 0
                    if wasRouteStep, slot.route[0] != 0xFF {
                        for i in 0..<13 { slot.route[i] = slot.route[i + 1] }
                        slot.route[13] = 0xFF
                        if slot.route[0] == 0xFF {
                            slot.targetMove = 0
                            Log.info(
                                "move-arrived u\(idx) (type=\(slot.type)) at pos=(\(goal.x),\(goal.y)) route-exhausted",
                                tracer: .label("move")
                            )
                        } else {
                            Log.debug(
                                "move-pop u\(idx) step-done, route[0]=\(slot.route[0]), pos=(\(goal.x),\(goal.y))",
                                tracer: .label("move")
                            )
                        }
                    } else {
                        // Arrived via targetMove fallback.
                        slot.targetMove = 0
                        Log.info(
                            "move-arrived u\(idx) (type=\(slot.type)) at pos=(\(goal.x),\(goal.y)) via=\(goalSource)",
                            tracer: .label("move")
                        )
                    }
                    host.units[idx] = slot
                    continue
                }

                let step = max(Int32(4), Int32(slot.speed) / 4)
                let longest = max(abs(dx), abs(dy))
                let stepX = dx * step / longest
                let stepY = dy * step / longest
                let priorX = slot.positionX
                let priorY = slot.positionY
                let priorOrient = slot.orientationCurrent
                slot.positionX = UInt16(clamping: Int32(slot.positionX) + stepX)
                slot.positionY = UInt16(clamping: Int32(slot.positionY) + stepY)
                // Orientation:
                //   - Route-driven step: lock to `route[0] * 32`. `route[0]`
                //     encodes an 8-way compass direction (0=N, 2=E, 4=S,
                //     6=W) and `* 32` lands squarely on the octant midpoint
                //     used by the sprite-atlas `to8` mapping. Recomputing
                //     from the continuous pos32 delta every tick made the
                //     byte oscillate around octant boundaries (N↔NW at
                //     byte ≈ 240), producing a visible sprite "blink" when
                //     the unit was a few pixels off the tile centerline.
                //     OpenDUNE's `Script_Unit_CalculateRoute` aligns
                //     orientation to `route[0] * 32` too — see
                //     `Functions.swift:816` for our port of that line.
                //   - targetMove fallback (no route): continuous direction
                //     from pos32 delta. This branch is rare (first tick
                //     after `orderMove` before `CalculateRoute` runs, and
                //     carryall `SetDestinationDirect`) so sub-tile drift
                //     is less of a problem.
                if goalSource == "route", slot.route[0] != 0xFF {
                    slot.orientationCurrent = Int8(bitPattern: slot.route[0] &* 32)
                } else {
                    let from = Pos32(x: slot.positionX, y: slot.positionY)
                    slot.orientationCurrent = Int8(bitPattern: Pos32.direction(from: from, to: goal))
                }
                // Per-tick trace for moving units. `move` tracer; gated at
                // .verbose since 12Hz × Nunits can get chatty. Trigger
                // `DUNEII_LOG_VERBOSE=1` to widen the filter.
                Log.verbose(
                    "move-tick u\(idx) (t=\(slot.type) a=\(slot.actionID)) pos=(\(priorX),\(priorY))→(\(slot.positionX),\(slot.positionY)) step=(\(stepX),\(stepY)) o=\(priorOrient)→\(slot.orientationCurrent) goal=(\(goal.x),\(goal.y)) via=\(goalSource) dist=\(manhattan)",
                    tracer: .label("move")
                )
                host.units[idx] = slot
            }
        }

        private mutating func tickUnits() {
            var query = Simulation.PoolQuery()
            while let slot = host.units.next(&query) {
                let idx = Int(slot.index)
                host.currentObject = .unit(poolIndex: idx)
                // OpenDUNE's `Script_Load` runs once per action change.
                // Load the per-unit-type entry point (mirrors
                // `Script_Load(&u->o.script, u->o.type)` in
                // `src/unit.c:521`) and then overwrite `variables[0]`
                // with the action — the top-level dispatch in UNIT.EMC
                // branches on `variables[0]`. Passing `action` as
                // `typeID` (earlier scheduler shape) landed the PC at
                // `entryPoints[action]` — a completely different unit
                // type's entry — and made trikes execute the ornithopter
                // prologue, etc.
                let action = Int(slot.actionID)
                if loadedUnitAction[idx] != action {
                    let type = Int(slot.type)
                    unitVM.load(engine: &unitEngines[idx], typeID: type)
                    unitEngines[idx].variables[0] = UInt16(truncatingIfNeeded: action)
                    Log.debug(
                        "unit \(idx) (type \(type) house \(slot.houseID)) → action \(action), pc=\(unitEngines[idx].pc)",
                        tracer: .label("scheduler")
                    )
                    loadedUnitAction[idx] = action
                }
                let priorPC = unitEngines[idx].pc
                dispatch(
                    engine: &unitEngines[idx],
                    vm: unitVM,
                    budget: Self.unitOpcodesPerTick
                )
                if unitEngines[idx].halted && priorPC != unitEngines[idx].pc {
                    Log.warning(
                        "unit \(idx) halted at pc=\(unitEngines[idx].pc)",
                        tracer: .label("scheduler")
                    )
                }
            }
        }

        private mutating func tickStructures() {
            var query = Simulation.PoolQuery()
            while let slot = host.structures.next(&query) {
                if Self.skippedStructureTypes.contains(slot.type) { continue }
                let idx = Int(slot.index)
                host.currentObject = .structure(poolIndex: idx)
                // Structures load their engine once by `type` (OpenDUNE
                // `Structure_Tick` → `Script_Load` on first run and on
                // `Structure_UpdateMap` calls). Reload when type flips.
                let type = Int(slot.type)
                if loadedStructureType[idx] != type {
                    structureVM.load(engine: &structureEngines[idx], typeID: type)
                    loadedStructureType[idx] = type
                }
                dispatch(
                    engine: &structureEngines[idx],
                    vm: structureVM,
                    budget: Self.structureOpcodesPerTick
                )
            }
        }

        /// Team tick — walks `host.teams.findArray` and runs each team's
        /// EMC engine under a 5-opcode budget. Matches OpenDUNE's
        /// `GameLoop_Team` driving each active team through its action
        /// script. When no `teamVM` was supplied at init, we reuse the
        /// unit VM — which typically halts on the first unresolved
        /// opcode, making this a safe no-op until a real TEAM.EMC is
        /// loaded and wired.
        private mutating func tickTeams() {
            for idx in host.teams.findArray where idx < teamEngines.count {
                host.currentObject = .team(poolIndex: idx)
                let action = Int(host.teams.slots[idx].action)
                if loadedTeamAction[idx] != action {
                    teamVM.load(engine: &teamEngines[idx], typeID: action)
                    loadedTeamAction[idx] = action
                }
                dispatch(
                    engine: &teamEngines[idx],
                    vm: teamVM,
                    budget: Self.teamOpcodesPerTick
                )
            }
        }

        private func dispatch(
            engine: inout Scripting.Engine,
            vm: Scripting.VM,
            budget: Int
        ) {
            if engine.delay != 0 {
                engine.delay &-= 1
                return
            }
            var remaining = budget
            while remaining > 0 && engine.delay == 0 {
                if vm.step(&engine) == .halted { break }
                remaining -= 1
            }
        }
    }
}
