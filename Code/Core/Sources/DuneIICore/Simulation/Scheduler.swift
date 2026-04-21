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

        public init(
            host: Scripting.Host,
            unitVM: Scripting.VM,
            structureVM: Scripting.VM,
            teamVM: Scripting.VM? = nil
        ) {
            self.host = host
            self.unitVM = unitVM
            self.structureVM = structureVM
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
            host.currentObject = nil
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
                    let tileX = UInt16(nextPacked & 0x3F)
                    let tileY = UInt16((nextPacked >> 6) & 0x3F)
                    slot.currentDestinationX = tileX &* 256 &+ 128
                    slot.currentDestinationY = tileY &* 256 &+ 128
                }

                // Pick the goal. Route-backed destination wins; else fall
                // back to the targetMove tile directly.
                let goal: Pos32
                if slot.currentDestinationX != 0 || slot.currentDestinationY != 0 {
                    goal = Pos32(x: slot.currentDestinationX, y: slot.currentDestinationY)
                } else if let t = Pos32.of(Scripting.EncodedIndex(raw: slot.targetMove), host: host) {
                    goal = t
                } else {
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
                        if slot.route[0] == 0xFF { slot.targetMove = 0 }
                    } else {
                        // Arrived via targetMove fallback.
                        slot.targetMove = 0
                    }
                    host.units[idx] = slot
                    continue
                }

                let step = max(Int32(4), Int32(slot.speed) / 4)
                let longest = max(abs(dx), abs(dy))
                let stepX = dx * step / longest
                let stepY = dy * step / longest
                slot.positionX = UInt16(clamping: Int32(slot.positionX) + stepX)
                slot.positionY = UInt16(clamping: Int32(slot.positionY) + stepY)
                let from = Pos32(x: slot.positionX, y: slot.positionY)
                slot.orientationCurrent = Int8(bitPattern: Pos32.direction(from: from, to: goal))
                host.units[idx] = slot
            }
        }

        private mutating func tickUnits() {
            var query = Simulation.PoolQuery()
            while let slot = host.units.next(&query) {
                let idx = Int(slot.index)
                host.currentObject = .unit(poolIndex: idx)
                // OpenDUNE's `Script_Load` runs once per action change.
                // Detect the delta here and load the matching entry point
                // so the engine starts at the right place in `UNIT.EMC`.
                let action = Int(slot.actionID)
                if loadedUnitAction[idx] != action {
                    unitVM.load(engine: &unitEngines[idx], typeID: action)
                    Log.debug(
                        "unit \(idx) (type \(slot.type) house \(slot.houseID)) → action \(action), pc=\(unitEngines[idx].pc)",
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
