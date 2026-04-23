import Foundation
import Testing
@testable import DuneIICore

/// Longer-horizon movement checks. Each test drives `Scheduler.tick()`
/// many times (up to ~800 ticks) and records per-tick position +
/// orientation + route head, then asserts:
///
///  - **Reachability:** the unit's `targetMove` clears within the
///    budget (`targetMove == 0` after arrival snap).
///  - **Continuity:** between any two consecutive ticks, neither axis
///    jumps by more than a tile's worth of pixels (256 px) — the fallback
///    slide's `min(speed*16, dist+16)` cap + the arrival snap should
///    keep per-tick pixel deltas bounded.
///  - **Orientation:** for route-driven motion the heading is octant-
///    locked (0, 32, 64, 96, 128, 160, 192, 224) matching N/NE/E/SE/S/SW/W/NW
///    per `route[0] * 32`. Fallback slides use continuous directions.
///  - **Obstacle avoidance:** pathfinder-built routes steer around
///    placed structures and mountain bands; no tick ever leaves the unit
///    inside a blocked tile.
///
/// Reference: `Simulation.Scheduler.tickMovement`
/// (`Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:979`), plus
/// OpenDUNE `Unit_MovementTick` (`src/unit.c:98`) and
/// `Unit_GetTileEnterScore` (`src/unit.c:2335`).
@Suite("Movement long-run — continuity, reachability, obstacle avoidance")
struct MovementLongRunTests {

    // Unit types we exercise here.
    private let TANK: UInt8 = 9        // tracked, turreted
    private let TRIKE: UInt8 = 13      // wheeled
    private let TROOPER: UInt8 = 5     // foot (infantry)
    private let REFINERY: UInt8 = 12

    // Octant-step coordinate deltas (in tiles) for N..NW. Index matches
    // OpenDUNE route-step direction byte values.
    private let octantDXDY: [(Int, Int)] = [
        ( 0, -1),   // 0  N
        ( 1, -1),   // 1  NE
        ( 1,  0),   // 2  E
        ( 1,  1),   // 3  SE
        ( 0,  1),   // 4  S
        (-1,  1),   // 5  SW
        (-1,  0),   // 6  W
        (-1, -1),   // 7  NW
    ]
    private let octantNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    // MARK: - Helpers

    /// Per-tick recording of the unit's kinematic state.
    private struct Trace {
        let tick: Int
        let posX: UInt16
        let posY: UInt16
        let orient: Int8
        let action: UInt8
        let routeHead: UInt8
        let targetMove: UInt16

        var tileX: Int { Int(posX) / 256 }
        var tileY: Int { Int(posY) / 256 }
    }

    /// Empty-VM scheduler. `landscape` defaults to all-sand; callers pass
    /// a custom closure for tests that need mountain bands / rock.
    private func scheduler(
        landscape: @escaping (UInt16) -> UInt8 = { _ in UInt8(LandscapeType.normalSand.rawValue) }
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(landscapeAt: landscape, spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm, teamVM: vm)
    }

    /// Spawn a ground unit centred on `tile` and run the full
    /// `Units.setSpeed` pipeline so `speedPerTick` / `speed` reflect the
    /// real per-type `movingSpeedFactor`.
    @discardableResult
    private func spawn(
        _ s: inout Simulation.Scheduler,
        type: UInt8,
        house: UInt8 = Simulation.House.atreides,
        at tile: (x: Int, y: Int)
    ) -> Int {
        let idx = s.host.units.allocateForType(type: type, houseID: house)!
        var u = s.host.units[idx]
        u.positionX = UInt16(tile.x * 256 + 128)
        u.positionY = UInt16(tile.y * 256 + 128)
        s.host.units[idx] = u
        Simulation.Units.setSpeed(poolIndex: idx, speedPercent: 255, units: &s.host.units)
        return idx
    }

    /// Drive the scheduler until the unit's `targetMove` clears (arrival
    /// snap) or `maxTicks` elapses. Returns the full per-tick trace so
    /// the caller can assert continuity invariants.
    private func driveUntilArrival(
        _ s: inout Simulation.Scheduler, unit idx: Int, maxTicks: Int
    ) -> [Trace] {
        var trace: [Trace] = []
        for i in 0..<maxTicks {
            let u = s.host.units[idx]
            trace.append(Trace(
                tick: i, posX: u.positionX, posY: u.positionY,
                orient: u.orientationCurrent, action: u.actionID,
                routeHead: u.route[0], targetMove: u.targetMove
            ))
            if u.targetMove == 0, u.route[0] == 0xFF { break }
            s.tick()
        }
        return trace
    }

    /// Largest single-tick pixel delta on either axis — the continuity
    /// metric. A teleport (tile-centre snap from far away) would show up
    /// here as a > 256 jump.
    private func maxStep(_ trace: [Trace]) -> (dx: Int, dy: Int) {
        var mx = 0, my = 0
        for i in 1..<trace.count {
            let dx = abs(Int(trace[i].posX) - Int(trace[i - 1].posX))
            let dy = abs(Int(trace[i].posY) - Int(trace[i - 1].posY))
            mx = max(mx, dx); my = max(my, dy)
        }
        return (mx, my)
    }

    /// Manually build a route via `Pathfinder.findRoute` and stamp it
    /// onto the unit. Tests that rely on structure / landscape
    /// avoidance need this since the empty EMC program never runs
    /// `Script_Unit_CalculateRoute`.
    private func stampRoute(
        _ s: inout Simulation.Scheduler,
        unit idx: Int, to dstTile: (x: Int, y: Int)
    ) {
        let u = s.host.units[idx]
        let src = Simulation.Pathfinder.packedTile(x: u.positionX, y: u.positionY)
        let dst = UInt16(dstTile.y * 64 + dstTile.x)
        let movement = Simulation.UnitInfo.lookup(u.type)?.movementType ?? .tracked
        // Reproduce `makeCalculateRouteUnit`'s scorer: treat buildings +
        // unit footprints as impassable, else fall back to the host's
        // landscapeAt lookup with the unit's movement type.
        let selfIndex = idx
        let unitsSnapshot = s.host.units
        let structuresSnapshot = s.host.structures
        let landscape = s.host.landscapeAt
        let scoreFn: Simulation.Pathfinder.TileEnterScore = { packed, _ in
            let tx = Int(packed & 0x3F)
            let ty = Int((packed >> 6) & 0x3F)
            // Structures (including the whole footprint) block.
            for sIdx in structuresSnapshot.findArray {
                let st = structuresSnapshot.slots[sIdx]
                let ax = Int(st.positionX) / 256
                let ay = Int(st.positionY) / 256
                let fp = Simulation.Structures.footprintTiles(
                    type: st.type, anchorX: ax, anchorY: ay
                )
                if fp.contains(where: { $0.0 == tx && $0.1 == ty }) { return 256 }
            }
            // Other non-winger, non-projectile units block. Crush rule:
            // tracked + harvester movers may enter foot-occupied tiles.
            let canCrushFoot = movement == .tracked || movement == .harvester
            for (i, other) in unitsSnapshot.slots.enumerated() {
                if i == selfIndex { continue }
                guard other.isUsed else { continue }
                if Simulation.Scheduler.isProjectileType(other.type) { continue }
                let occupantMT = Simulation.UnitInfo.lookup(other.type)?.movementType
                if occupantMT == .winger { continue }
                if occupantMT == .foot, canCrushFoot { continue }
                let utx = Int(other.positionX) / 256
                let uty = Int(other.positionY) / 256
                if utx == tx && uty == ty { return 256 }
            }
            // Landscape gate.
            if let fn = landscape {
                let raw = fn(packed)
                if let type = LandscapeType(rawValue: Int(raw)) {
                    let info = Simulation.LandscapeInfo.lookup(type)
                    let mt = Int(movement.rawValue)
                    if mt < info.movementSpeed.count,
                       info.movementSpeed[mt] == 0 {
                        return 256
                    }
                    return Int32(info.movementSpeed[mt])
                }
            }
            return 128
        }
        let route = Simulation.Pathfinder.findRoute(
            src: src, dst: dst, bufferSize: 40, score: scoreFn
        )
        var slot = s.host.units[idx]
        let copyCount = min(route.size, 14)
        for i in 0..<14 {
            slot.route[i] = i < copyCount ? route.buffer[i] : 0xFF
        }
        slot.targetMove = Scripting.EncodedIndex.tile(packed: dst).raw
        slot.actionID = Simulation.ActionID.move
        slot.currentDestinationX = 0
        slot.currentDestinationY = 0
        s.host.units[idx] = slot
    }

    // MARK: - 1. Cardinal axis: N/E/S/W fallback slide

    @Test("Tank slides east 10 tiles via fallback: arrives, continuous, heading ~E")
    func slideEast10TilesContinuous() {
        var s = scheduler()
        let idx = spawn(&s, type: TANK, at: (x: 5, y: 10))
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 15, tileY: 10, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 600)
        let last = trace.last!
        #expect(last.targetMove == 0, "tank should arrive; trace end = \(last.tileX),\(last.tileY) tm=\(String(format: "0x%04X", last.targetMove))")
        #expect(last.tileX == 15 && last.tileY == 10)
        let step = maxStep(trace)
        #expect(step.dx <= 256, "per-tick X delta \(step.dx) exceeded 1 tile — position jumped")
        #expect(step.dy <= 256)
        // Fallback slide from (5,10) to (15,10) is pure +X; orientation
        // byte should be 64 (E) or within ±2 of it.
        let moving = trace.filter { $0.orient != 0 || $0.tick > 3 }
        let movingOrients = moving.map { Int($0.orient) }
        for o in movingOrients {
            let oByte = (o + 256) % 256
            #expect(abs(oByte - 64) <= 4, "orientation \(oByte) strays from E (64)")
        }
    }

    @Test("Tank slides west 8 tiles via fallback: arrives, continuous")
    func slideWest8TilesContinuous() {
        var s = scheduler()
        let idx = spawn(&s, type: TANK, at: (x: 15, y: 10))
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 7, tileY: 10, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 600)
        let last = trace.last!
        #expect(last.targetMove == 0)
        #expect(last.tileX == 7 && last.tileY == 10)
        let step = maxStep(trace)
        #expect(step.dx <= 256 && step.dy <= 256)
    }

    @Test("Trike slides south 10 tiles via fallback: arrives, monotonic Y")
    func slideSouth10TilesMonotonic() {
        var s = scheduler()
        let idx = spawn(&s, type: TRIKE, at: (x: 10, y: 5))
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 10, tileY: 15, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 400)
        let last = trace.last!
        #expect(last.targetMove == 0)
        #expect(last.tileY == 15)
        // Y must be non-decreasing across the whole trace (no backtrack).
        var regressionCount = 0
        for i in 1..<trace.count {
            if trace[i].posY < trace[i - 1].posY { regressionCount += 1 }
        }
        #expect(regressionCount == 0, "unit moved north on \(regressionCount) ticks while ordered south")
    }

    // MARK: - 2. All-8-directions sweep

    @Test("Tank reliably reaches target in all 8 directions, continuity preserved", arguments: 0..<8)
    func eightDirectionsReachAndContinuous(octant: Int) {
        var s = scheduler()
        let start = (x: 20, y: 20)
        let (dx, dy) = octantDXDY[octant]
        let dist = 8
        let goal = (x: start.x + dx * dist, y: start.y + dy * dist)
        let idx = spawn(&s, type: TANK, at: start)
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: goal.x, tileY: goal.y, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 800)
        let last = trace.last!
        #expect(
            last.tileX == goal.x && last.tileY == goal.y,
            "octant \(octantNames[octant]): expected tile (\(goal.x),\(goal.y)), got (\(last.tileX),\(last.tileY))"
        )
        #expect(last.targetMove == 0, "octant \(octantNames[octant]): targetMove not cleared")
        let step = maxStep(trace)
        #expect(
            step.dx <= 256 && step.dy <= 256,
            "octant \(octantNames[octant]): per-tick delta (\(step.dx),\(step.dy)) exceeded 1 tile"
        )
    }

    // MARK: - 3. Route-driven orientation stays octant-locked

    @Test("Route of 8 NE steps keeps orientation exactly at 32 (NE) throughout")
    func routeNEKeepsOrientationLocked() {
        var s = scheduler()
        let idx = spawn(&s, type: TANK, at: (x: 5, y: 20))
        // Stamp an 8-step NE route by hand.
        var slot = s.host.units[idx]
        for i in 0..<8 { slot.route[i] = 1 /* NE */ }
        slot.route[8] = 0xFF
        slot.targetMove = Scripting.EncodedIndex.tile(
            packed: UInt16((20 - 8) * 64 + (5 + 8))
        ).raw
        slot.actionID = Simulation.ActionID.move
        s.host.units[idx] = slot

        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 800)
        // Tick 0's trace is captured *before* the first `tickMovement`
        // run, so orient is still the initial 0. Skip it; every tick
        // thereafter while the route head is still NE (=1) must show
        // the locked byte 32.
        for t in trace where t.tick > 0 {
            if t.routeHead == 1 {
                #expect(t.orient == 32, "orient drifted to \(t.orient) during NE route step at tick \(t.tick)")
            }
        }
        let last = trace.last!
        #expect(last.tileX == 13 && last.tileY == 12, "final tile (\(last.tileX),\(last.tileY))")
    }

    @Test("Route of 6 N steps keeps orientation at 0 and Y strictly non-increasing")
    func routeNMonotonicY() {
        var s = scheduler()
        let idx = spawn(&s, type: TANK, at: (x: 10, y: 20))
        var slot = s.host.units[idx]
        for i in 0..<6 { slot.route[i] = 0 /* N */ }
        slot.route[6] = 0xFF
        slot.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(14 * 64 + 10)).raw
        slot.actionID = Simulation.ActionID.move
        s.host.units[idx] = slot

        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 400)
        for t in trace where t.routeHead == 0 {
            #expect(t.orient == 0)
        }
        for i in 1..<trace.count {
            #expect(
                trace[i].posY <= trace[i - 1].posY,
                "Y regressed at tick \(trace[i].tick): \(trace[i - 1].posY) → \(trace[i].posY)"
            )
        }
        let last = trace.last!
        #expect(last.tileY == 14 && last.tileX == 10)
    }

    // MARK: - 4. Pathfind around a structure

    @Test("Tank routes around a refinery sitting directly between start and goal")
    func routeAroundRefinery() {
        var s = scheduler()
        // Block (10,10) / (11,10) / (10,11) / (11,11) with a 2×2 REFINERY
        // anchored at (10, 10).
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(10 * 256)
        r.positionY = UInt16(10 * 256)
        s.host.structures[rIdx] = r

        let idx = spawn(&s, type: TANK, at: (x: 5, y: 10))
        stampRoute(&s, unit: idx, to: (x: 18, y: 10))
        // Sanity: route was actually built.
        #expect(s.host.units[idx].route[0] != 0xFF, "pathfinder returned empty route")

        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 1000)
        let last = trace.last!
        #expect(last.tileX == 18 && last.tileY == 10, "final tile (\(last.tileX),\(last.tileY))")
        #expect(last.targetMove == 0)

        // No tick should place the unit on the refinery footprint.
        let footprint = Simulation.Structures.footprintTiles(
            type: REFINERY, anchorX: 10, anchorY: 10
        )
        for t in trace {
            let onFootprint = footprint.contains { $0.0 == t.tileX && $0.1 == t.tileY }
            #expect(!onFootprint, "unit entered refinery tile (\(t.tileX),\(t.tileY)) at tick \(t.tick)")
        }

        // Continuity.
        let step = maxStep(trace)
        #expect(step.dx <= 256 && step.dy <= 256)
    }

    // MARK: - 5. Pathfind around a mountain band

    @Test("Tank routes around a small mountain block (x=10, y=9..11)")
    func routeAroundMountainBand() {
        // Tiny mountain block — single column x=10 for y=9..11. A
        // 14-step route buffer is plenty to detour south around it.
        let landscape: (UInt16) -> UInt8 = { packed in
            let tx = Int(packed & 0x3F)
            let ty = Int((packed >> 6) & 0x3F)
            if tx == 10, (9...11).contains(ty) {
                return UInt8(LandscapeType.entirelyMountain.rawValue)
            }
            return UInt8(LandscapeType.normalSand.rawValue)
        }
        var s = scheduler(landscape: landscape)
        let start = (x: 5, y: 10)
        let goal = (x: 14, y: 10)
        let idx = spawn(&s, type: TANK, at: start)
        stampRoute(&s, unit: idx, to: goal)
        #expect(s.host.units[idx].route[0] != 0xFF, "pathfinder gave no route around mountain")

        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 1500)
        let last = trace.last!
        #expect(
            last.tileX == goal.x && last.tileY == goal.y,
            "final tile (\(last.tileX),\(last.tileY)); trace length \(trace.count)"
        )

        // No tick should plant a tracked vehicle on a mountain tile.
        for t in trace {
            let onMountain = t.tileX == 10 && (9...11).contains(t.tileY)
            #expect(
                !onMountain,
                "tank entered mountain tile (\(t.tileX),\(t.tileY)) at tick \(t.tick)"
            )
        }
        let step = maxStep(trace)
        #expect(step.dx <= 256 && step.dy <= 256)
    }

    // MARK: - 6. Position never jumps (fallback) even over long slides

    @Test("Long diagonal fallback slide: every tick's position delta ≤ speed*16 + small slack")
    func longDiagonalSlideStepCap() {
        var s = scheduler()
        let idx = spawn(&s, type: TRIKE, at: (x: 5, y: 5))
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 25, tileY: 25, units: &s.host.units
        )
        let speedClamp = Int(s.host.units[idx].speed) * 16
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 1500)
        let last = trace.last!
        #expect(last.tileX == 25 && last.tileY == 25)
        // Per-tick delta must not exceed `speed*16` pixels on either axis
        // (plus a tiny slack for the `distance+16` cap near arrival).
        let slack = 20
        for i in 1..<trace.count {
            let dx = abs(Int(trace[i].posX) - Int(trace[i - 1].posX))
            let dy = abs(Int(trace[i].posY) - Int(trace[i - 1].posY))
            #expect(
                dx <= speedClamp + slack,
                "tick \(trace[i].tick): x-delta \(dx) > cap \(speedClamp + slack) (speed=\(s.host.units[idx].speed))"
            )
            #expect(
                dy <= speedClamp + slack,
                "tick \(trace[i].tick): y-delta \(dy) > cap \(speedClamp + slack)"
            )
        }
    }

    // MARK: - 7. Infantry occupancy — OpenDUNE parity probe

    /// OpenDUNE `Unit_GetTileEnterScore` (`src/unit.c:2354`) lets TRACKED
    /// and HARVESTER units enter tiles occupied by MOVEMENT_FOOT units
    /// (visually: tanks crush infantry). Our current
    /// `Scheduler.isTilePassable` treats every non-winger / non-projectile
    /// unit as a wall, so this test documents the GAP — tanks shouldn't
    /// need to detour around a single trooper on their path. Expected to
    /// FAIL until we port that parity rule.
    @Test("Tank path through a single infantry blocker still reaches goal")
    func tankIgnoresInfantryOnPath() {
        var s = scheduler()
        // Trooper (foot) on the straight line between start and goal.
        let tIdx = s.host.units.allocateForType(type: TROOPER, houseID: Simulation.House.harkonnen)!
        var t = s.host.units[tIdx]
        t.positionX = UInt16(10 * 256 + 128)
        t.positionY = UInt16(10 * 256 + 128)
        s.host.units[tIdx] = t

        let idx = spawn(&s, type: TANK, at: (x: 5, y: 10))
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 15, tileY: 10, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 800)
        let last = trace.last!
        // Current implementation: fallback slide doesn't re-check unit
        // occupancy per-tile, so the tank WILL reach (15,10) — but any
        // route-driven version does. We pin the reached-goal invariant.
        #expect(
            last.tileX == 15 && last.tileY == 10,
            "tank failed to reach goal past infantry; ended at (\(last.tileX),\(last.tileY))"
        )
    }

    // MARK: - 8. Building placed mid-move halts cleanly and keeps targetMove

    @Test("Route-step into a structure halts cleanly: route clears, targetMove survives, no pre-halt footprint entry")
    func halfwayBlockedRouteKeepsTargetMove() {
        var s = scheduler()
        // Pre-stamp: unit at (5,10), heading east; refinery anchored at
        // (7,10) so route step into tile (6,10) is still passable but
        // step into (7,10) isn't.
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(7 * 256)
        r.positionY = UInt16(10 * 256)
        s.host.structures[rIdx] = r

        let idx = spawn(&s, type: TANK, at: (x: 5, y: 10))
        var slot = s.host.units[idx]
        // Force a straight east route (2 = E). Steps: (6,10) ok, (7,10)
        // blocked.
        slot.route[0] = 2; slot.route[1] = 2
        slot.route[2] = 0xFF
        slot.targetMove = Scripting.EncodedIndex.tile(packed: UInt16(10 * 64 + 12)).raw
        slot.actionID = Simulation.ActionID.move
        s.host.units[idx] = slot

        // Drive until the halt (route clears). Stop there — the
        // post-halt fallback slide's behaviour through intermediate
        // obstacles is covered by `fallbackSlideGoesThroughStructure`
        // below (documented gap).
        var trace: [Trace] = []
        var haltTick: Int? = nil
        for i in 0..<300 {
            let u = s.host.units[idx]
            let t = Trace(
                tick: i, posX: u.positionX, posY: u.positionY,
                orient: u.orientationCurrent, action: u.actionID,
                routeHead: u.route[0], targetMove: u.targetMove
            )
            trace.append(t)
            // First tick where `route[0]` just cleared while `targetMove`
            // is still live = the halt tick (self-heal state).
            if haltTick == nil, i > 0, t.routeHead == 0xFF, t.targetMove != 0 {
                haltTick = i
                break
            }
            s.tick()
        }
        #expect(haltTick != nil, "scheduler never halted; trace len=\(trace.count)")

        // Refinery footprint (7,10)/(8,10)/(7,11)/(8,11). Up to and
        // including the halt tick, the unit must NEVER have entered it.
        let footprint = Simulation.Structures.footprintTiles(
            type: REFINERY, anchorX: 7, anchorY: 10
        )
        for t in trace {
            let onFp = footprint.contains { $0.0 == t.tileX && $0.1 == t.tileY }
            #expect(!onFp, "pre-halt tank entered refinery footprint (\(t.tileX),\(t.tileY)) at tick \(t.tick)")
        }
        let step = maxStep(trace)
        #expect(step.dx <= 256 && step.dy <= 256)
        // Halt state: route cleared + targetMove preserved (verified by
        // the loop break condition, re-asserted here for clarity).
        let lastU = s.host.units[idx]
        #expect(lastU.route[0] == 0xFF, "route should be cleared at halt")
        #expect(lastU.targetMove != 0, "targetMove must survive the halt for replan")
    }

    /// Regression: the fallback slide now samples `isTilePassable` on
    /// each tile-crossing and halts (keeping `targetMove` for replan)
    /// instead of clipping through a building. Without an EMC-driven
    /// `CalculateRoute` the unit will halt at the refinery edge — real
    /// gameplay has the script dispatch trigger a replan the next time
    /// the unit's action tick runs.
    @Test("Fallback slide halts at a structure instead of clipping its footprint")
    func fallbackSlideHaltsAtStructure() {
        var s = scheduler()
        let rIdx = s.host.structures.allocate(
            at: 0, type: REFINERY, houseID: Simulation.House.harkonnen
        )!
        var r = s.host.structures[rIdx]
        r.positionX = UInt16(10 * 256)
        r.positionY = UInt16(10 * 256)
        s.host.structures[rIdx] = r

        let idx = spawn(&s, type: TANK, at: (x: 5, y: 10))
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 15, tileY: 10, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 800)

        let footprint = Simulation.Structures.footprintTiles(
            type: REFINERY, anchorX: 10, anchorY: 10
        )
        let entered = trace.contains { t in
            footprint.contains { $0.0 == t.tileX && $0.1 == t.tileY }
        }
        #expect(!entered, "fallback slide entered refinery footprint — per-tile gate regressed")
        // Targetmove must survive the halt so the script layer can replan.
        let last = s.host.units[idx]
        #expect(last.targetMove != 0, "targetMove must survive fallback-slide halt for replan")
        // Unit should be stopped adjacent-west of the refinery footprint.
        let lastTrace = trace.last!
        #expect(lastTrace.tileX <= 9, "tank ended past refinery edge at (\(lastTrace.tileX),\(lastTrace.tileY))")
    }

    // MARK: - 10. OpenDUNE crush semantics — tracked + harvester ignore foot

    /// Port of `Unit_GetTileEnterScore` (`src/unit.c:2335..2355`). Tracked
    /// and harvester movers may enter foot-occupied tiles (tanks crush
    /// infantry). A trooper on the pathfinder's straight line between
    /// tank start and goal no longer forces a detour; the route should
    /// go directly through the trooper's tile.
    @Test("Tracked tank's pathfinder route runs straight through infantry (crush parity)")
    func trackedTankPathfindsThroughInfantry() {
        var s = scheduler()
        // Trooper sitting on the direct E line between (5,10) and (15,10).
        let tIdx = s.host.units.allocateForType(type: TROOPER, houseID: Simulation.House.harkonnen)!
        var t = s.host.units[tIdx]
        t.positionX = UInt16(10 * 256 + 128)
        t.positionY = UInt16(10 * 256 + 128)
        s.host.units[tIdx] = t

        let idx = spawn(&s, type: TANK, at: (x: 5, y: 10))
        stampRoute(&s, unit: idx, to: (x: 15, y: 10))
        #expect(s.host.units[idx].route[0] != 0xFF, "pathfinder produced empty route")

        // All 10 route bytes should be 2 (E) since crush rule lets the
        // scorer treat the trooper's tile as walkable for a tank.
        let route = Array(s.host.units[idx].route.prefix(10))
        for (i, step) in route.enumerated() where step != 0xFF {
            #expect(step == 2, "route step \(i) = \(step), expected 2 (E) — detour around trooper?")
        }

        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 1000)
        let last = trace.last!
        #expect(last.tileX == 15 && last.tileY == 10)
        // Trajectory must cross the trooper's tile.
        let crossed = trace.contains { $0.tileX == 10 && $0.tileY == 10 }
        #expect(crossed, "tank never crossed the trooper's tile despite crush parity")
    }

    /// Inverse of the crush rule: a **wheeled** trike should NOT be
    /// allowed to cross foot-occupied tiles — only tracked + harvester
    /// get that pass per OpenDUNE. The pathfinder must route around.
    @Test("Wheeled trike still routes around infantry (crush rule is tracked/harvester-only)")
    func wheeledTrikeDetoursAroundInfantry() {
        var s = scheduler()
        let tIdx = s.host.units.allocateForType(type: TROOPER, houseID: Simulation.House.harkonnen)!
        var t = s.host.units[tIdx]
        t.positionX = UInt16(10 * 256 + 128)
        t.positionY = UInt16(10 * 256 + 128)
        s.host.units[tIdx] = t

        let idx = spawn(&s, type: TRIKE, at: (x: 5, y: 10))
        stampRoute(&s, unit: idx, to: (x: 15, y: 10))
        #expect(s.host.units[idx].route[0] != 0xFF, "pathfinder produced empty route")

        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 1500)
        let last = trace.last!
        #expect(last.tileX == 15 && last.tileY == 10)
        // Trike must NOT cross the trooper's tile.
        let crossed = trace.contains { $0.tileX == 10 && $0.tileY == 10 }
        #expect(!crossed, "trike walked through infantry — wheeled should detour")
    }

    // MARK: - 9. Final sanity — no teleport across any test's setup

    // MARK: - 11. Route-driven motion has no Δ=0 stalls at tile boundaries

    /// Regression for the 2026-04-23 "jumps in movement" fix. Before
    /// the inline route-pop in `tickMovement`'s overshoot-snap branch,
    /// a route-driven tank stalled for one tick at every tile center:
    /// Δ=32 (step + snap), Δ=0 (arrival branch pops route without
    /// firing a step), Δ=16, Δ=16, … → visible stutter every 16 ticks.
    /// After the fix the arrival branch fires the route-pop inline, so
    /// the very next tick picks up the new leg and advances normally.
    ///
    /// The invariant: across a long route-driven move, the number of
    /// zero-axis-delta ticks (Δx==Δy==0) between the "unit is moving
    /// now" boundary and arrival stays bounded by a small slack — we
    /// allow up to the number of tile boundaries crossed (= one Δ=0
    /// per setSpeed call from `CalculateRoute`) and the warm-up tick.
    @Test("Route-driven tank has no per-tile-boundary Δ=0 stall")
    func routeDrivenMovementNoPerTileStall() {
        var s = scheduler()
        let idx = spawn(&s, type: TANK, at: (x: 5, y: 20))
        stampRoute(&s, unit: idx, to: (x: 18, y: 20))
        #expect(s.host.units[idx].route[0] != 0xFF)
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 1500)
        // Count ticks where the unit was actively moving (speed>0)
        // but didn't advance position on either axis.
        var stalls = 0
        var first = true
        for i in 1..<trace.count {
            let p = trace[i - 1]
            let c = trace[i]
            // Only count during the motion phase (speed > 0 implies
            // targetMove still active earlier). Simpler: only count
            // ticks where the *previous* tick already had targetMove
            // set.
            if p.targetMove == 0 { continue }
            let dx = Int(c.posX) - Int(p.posX)
            let dy = Int(c.posY) - Int(p.posY)
            if dx == 0 && dy == 0 {
                stalls += 1
                if first {
                    first = false
                }
            }
        }
        // Tile boundaries crossed ≈ 13. Allow up to 3 stalls total
        // (warm-up + occasional CalculateRoute reset). Pre-fix this
        // was ~13 — one per tile boundary. The fix brings it under 4.
        #expect(stalls <= 3,
                "route-driven move stalled \(stalls) times — expected ≤ 3 (pre-fix this was ~13, one per tile)")
    }

    @Test("Fallback slide arrival snap never skips > 1 tile in a single tick")
    func arrivalSnapDoesNotTeleport() {
        // Pick a starting sub-tile position so the final step's
        // `distBefore - speed*16` lands < arrivalThreshold; the
        // arrival-snap branch should set position to goal centre.
        // We then confirm the pre-snap → post-snap delta is ≤ 1 tile.
        var s = scheduler()
        let idx = spawn(&s, type: TANK, at: (x: 8, y: 10))
        // Drop the unit 200 px to the left of tile-centre so the slide
        // has a natural approach window.
        var slot = s.host.units[idx]
        slot.positionX = UInt16(8 * 256 + 128 - 200)
        s.host.units[idx] = slot
        Simulation.Units.orderMove(
            poolIndex: idx, tileX: 9, tileY: 10, units: &s.host.units
        )
        let trace = driveUntilArrival(&s, unit: idx, maxTicks: 200)
        let last = trace.last!
        #expect(last.tileX == 9 && last.tileY == 10)
        let step = maxStep(trace)
        #expect(step.dx <= 256 && step.dy <= 256)
    }
}
