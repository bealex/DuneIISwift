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

        /// Default per-tick opcode budget for unit EMC engines. Kept at 7
        /// for playable gameplay cadence (our sim ticks ~12 Hz; OpenDUNE
        /// runs 52 opcodes *every 5 game ticks*, i.e. ~10 / tick average).
        /// The parity harness bumps this to OpenDUNE's `SCRIPT_UNIT_OPCODES_PER_TICK + 2 = 52`
        /// via `unitOpcodesPerTick` override so tick-1 dispatch matches.
        public static let unitOpcodesPerTick = 7
        public static let structureOpcodesPerTick = 3
        public static let teamOpcodesPerTick = 5

        /// Per-instance override of `unitOpcodesPerTick`. When non-nil,
        /// `dispatch(engine:vm:budget:)` uses this instead of the static.
        /// Used by `Simulation.ParityHarness` to match OpenDUNE's 52-opcode
        /// burst (`SCRIPT_UNIT_OPCODES_PER_TICK + 2`, `src/script/script.h:7`).
        public var unitOpcodeBudget: Int
        public var structureOpcodeBudget: Int
        public var teamOpcodeBudget: Int

        /// Gating toggles for sim passes that are stopgaps for unwired
        /// EMC paths. With real `UNIT.EMC` loaded (parity harness), these
        /// stopgaps become counterproductive because they pre-empt the
        /// script's own decisions. Gameplay tests keep them on (default
        /// `true`); the parity harness flips them off.
        ///
        /// `tickAttackHoldEnabled`: our manual "face target + halt at
        /// fire range" pass for ATTACK units. OpenDUNE's UNIT.EMC does
        /// this via `Script_Unit_MoveToTarget` + `Script_Unit_Fire`; with
        /// real EMC, our manual clear of `targetMove` inside fire range
        /// conflicts with the script's own target tracking.
        public var tickAttackHoldEnabled: Bool = true
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

        /// STARPORT slice 5b — live per-game stock. Indexed by
        /// `UnitInfo.typeID` (27 entries). Seeded from
        /// `Scenario.choamInventory` at load; mutated by order commits
        /// (`Simulation.Structures.commitStarportOrder(...)`) and the
        /// per-game "random new-stock bump" pass that runs every
        /// `starportAvailabilityCadenceTicks`. The save chunk's
        /// `SaveInfo.starportAvailable` also feeds this array.
        ///
        /// Port of OpenDUNE's global `g_starportAvailable[UNIT_MAX]`
        /// (`src/unit.c:57`); we keep it on the scheduler rather than
        /// at module scope so tests can spin up fresh worlds without
        /// cross-talk.
        public var starportStock: [Int16] = [Int16](repeating: 0, count: 27)

        /// Cadence of `tickStarportDelivery`. OpenDUNE fires this every
        /// 180 game ticks; our sim runs at a lower rate so we use a
        /// matching "every 30 sim ticks ≈ 5 seconds" budget.
        public static let starportDeliveryCadenceTicks = 30
        /// Cadence of `tickStarportAvailability` — the random stock
        /// refresh. OpenDUNE fires every 1800 game ticks (~60 s); our
        /// cadence is every 300 sim ticks, same wall-clock ballpark.
        public static let starportAvailabilityCadenceTicks = 300
        /// Port of `HouseInfo.starportDeliveryTime` (= 10 for houses
        /// 0..2, 0 for 3..5). Counts in `tickStarport` units.
        public static let starportDeliveryTimeByHouse: [UInt16] = [10, 10, 10, 0, 0, 0]
        private var starportDeliveryTickCounter: Int = 0
        private var starportAvailabilityTickCounter: Int = 0

        /// Landscape-iconGroup sprite used to reset a spice-bloom
        /// tile's `groundTileID` after detonation (OpenDUNE
        /// `Map_Bloom_ExplodeSpice` at `src/map.c:675`). `0` disables
        /// the bloom-detonation pass entirely — tests + trivial
        /// schedulers leave it unset.
        public var bloomSandTileID: UInt16 = 0

        /// Current game-speed bucket in OpenDUNE's 0..4 range (2 = the
        /// canonical "normal" cadence). Drives `Tools_AdjustToGameSpeed`
        /// in `Units.setSpeed` and the per-tick movement accumulator —
        /// at the default 2 both calls are identity, so leaving this
        /// alone keeps the scheduler bit-identical to the pre-port
        /// behaviour. Non-default values are used by the tick-parity
        /// harness to match OpenDUNE at other game-speed settings.
        public var gameSpeed: UInt8 = 2

        /// Scenario playable rect — port of OpenDUNE
        /// `g_mapInfos[mapScale]` (`src/map.c:57`). Seeded by the
        /// scene / runtime from `Scenario.playableRect` at load so the
        /// auto-harvester's spice seek never strays outside the
        /// scenario's authoritative boundary. Default covers the whole
        /// 64×64 grid so tests that don't care can leave it unset.
        public var playableRect: (originX: Int, originY: Int, width: Int, height: Int) = (0, 0, 64, 64)

        /// Auto-harvester spice-seek radius (tiles) — how far away the
        /// `tickHarvesting` pass is willing to look for a fresh spice
        /// patch when a harvester stands idle off-spice. OpenDUNE's
        /// `Map_SearchSpice` calls from C pass radius 10 (harvester
        /// spawn); the in-EMC seek logic uses a larger effective
        /// radius since it loops. Picking 20 is a conservative middle
        /// ground: covers a reasonable fraction of the playable rect
        /// without letting harvesters trundle across the whole map to
        /// a distant patch they'd never reasonably pick on foot.
        public static let autoHarvestSpiceSearchRadius = 20

        /// Structure type IDs that have no script and are skipped during
        /// dispatch. Mirrors OpenDUNE's `STRUCTURE_SLAB_1x1`,
        /// `STRUCTURE_SLAB_2x2`, `STRUCTURE_WALL`.
        public static let skippedStructureTypes: Set<UInt8> = [0, 1, 14]

        /// Types 18..24 are projectiles — MISSILE_*, BULLET, SONIC_BLAST.
        /// They detonate on arrival at `currentDestination` rather than
        /// resuming along a route. Matches OpenDUNE's `flags.isBullet`
        /// group in `UnitInfo`.
        public static func isProjectileType(_ type: UInt8) -> Bool {
            return (18...24).contains(type)
        }

        /// Finds the nearest passable 8-neighbour of `target` (for the
        /// given `movementType`) closest to `from` by squared
        /// distance. Returns nil when no neighbour is passable. Used
        /// by `tickMovement`'s fallback to redirect a unit heading
        /// toward an impassable tile (enemy CYARD etc.) to an adjacent
        /// tile instead.
        func nearestPassableNeighbor(
            of target: (Int, Int),
            from src: (Int, Int),
            movementType: MovementType
        ) -> (Int, Int)? {
            let offs: [(Int, Int)] = [
                (0, -1), (1, -1), (1, 0), (1, 1),
                (0, 1), (-1, 1), (-1, 0), (-1, -1)
            ]
            var best: (Int, Int, Int)? = nil
            for (dx, dy) in offs {
                let nx = target.0 + dx
                let ny = target.1 + dy
                guard (0..<64).contains(nx), (0..<64).contains(ny) else { continue }
                guard isTilePassable(tileX: nx, tileY: ny, movementType: movementType) else { continue }
                let d = (nx - src.0) * (nx - src.0) + (ny - src.1) * (ny - src.1)
                if best == nil || d < best!.2 {
                    best = (nx, ny, d)
                }
            }
            if let best { return (best.0, best.1) }
            return nil
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
        /// tiles are never passable. When `excludingUnit` is supplied
        /// the mover's own tile skips the unit-occupancy check so the
        /// pathfinder can start from the mover's current position.
        func isTilePassable(
            tileX: Int, tileY: Int, movementType: MovementType,
            excludingUnit: Int? = nil
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
            // Unit occupancy. OpenDUNE's `Unit_GetTileEnterScore`
            // (`src/unit.c:2335..2355`) blocks unit-occupied tiles EXCEPT
            // that tracked + harvester movers can enter foot-occupied
            // tiles (crush semantics: tanks + harvesters drive over
            // infantry). Projectiles and wingers never block.
            let canCrushFoot = movementType == .tracked || movementType == .harvester
            for idx in host.units.findArray {
                if idx == excludingUnit { continue }
                let u = host.units.slots[idx]
                guard u.isUsed else { continue }
                if Self.isProjectileType(u.type) { continue }
                let occupantMT = Simulation.UnitInfo.lookup(u.type)?.movementType
                if occupantMT == .winger { continue }
                if occupantMT == .foot, canCrushFoot { continue }
                let utx = Int(u.positionX) / 256
                let uty = Int(u.positionY) / 256
                if utx == tileX && uty == tileY { return false }
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

        /// Port of OpenDUNE `Map_SearchSpice` (`src/map.c:1117`). Picks
        /// the best spice tile within `radius` (Chebyshev + Euclidean
        /// blend via `Tile_GetDistancePacked`) of `from`, clamped to
        /// `playableRect` — harvesters never stray off the scenario's
        /// authoritative playable area, matching OpenDUNE's
        /// `g_mapInfos[mapScale]` bounding box used throughout
        /// `Map_SearchSpice`.
        ///
        /// Two preference trackers:
        /// - `packed2` / `radius2`: best **thick** spice within a tight
        ///   radius (4 tiles, per the reference — a quality bonus that
        ///   steers harvesters toward fat patches even if there's thin
        ///   spice closer).
        /// - `packed1` / `radius1`: best **thin** (or fallback) spice
        ///   within `radius`.
        ///
        /// Tiles are skipped when they hold a structure or a
        /// non-projectile / non-winger unit (matches OpenDUNE's
        /// `hasStructure` + `Unit_Get_ByPackedTile` gates). The mover
        /// itself is skipped via `excludingUnit`.
        ///
        /// Returns nil when no spice exists in range.
        static func findSpiceNear(
            from: (x: Int, y: Int),
            radius: Int,
            playableRect: (originX: Int, originY: Int, width: Int, height: Int),
            map: SpiceMap,
            structures: StructurePool,
            units: UnitPool,
            excludingUnit: Int
        ) -> (x: Int, y: Int)? {
            // Clamp the search window to the intersection of
            // (from ± radius) and the playable rect.
            let rectMaxX = playableRect.originX + playableRect.width - 1
            let rectMaxY = playableRect.originY + playableRect.height - 1
            let xmin = max(from.x - radius, playableRect.originX)
            let xmax = min(from.x + radius, rectMaxX)
            let ymin = max(from.y - radius, playableRect.originY)
            let ymax = min(from.y + radius, rectMaxY)
            if xmin > xmax || ymin > ymax { return nil }

            // Precompute occupied tiles so the inner loop stays tight.
            // Structures: every footprint tile of every allocated
            // structure contributes. Walls / concrete / ruins are in
            // `findArray` (not the reserved aggregates), so the scan is
            // bounded.
            var structureOccupied = Set<Int>()
            for sIdx in structures.findArray {
                let s = structures.slots[sIdx]
                let ax = Int(s.positionX) / 256
                let ay = Int(s.positionY) / 256
                let fp = Structures.footprintTiles(type: s.type, anchorX: ax, anchorY: ay)
                for (fx, fy) in fp {
                    structureOccupied.insert(fy * 64 + fx)
                }
            }
            var unitOccupied = Set<Int>()
            for uIdx in units.findArray {
                if uIdx == excludingUnit { continue }
                let u = units.slots[uIdx]
                guard u.isUsed else { continue }
                if Self.isProjectileType(u.type) { continue }
                if let info = UnitInfo.lookup(u.type),
                   info.movementType == .winger { continue }
                let utx = Int(u.positionX) / 256
                let uty = Int(u.positionY) / 256
                unitOccupied.insert(uty * 64 + utx)
            }

            // OpenDUNE's `Tile_GetDistancePacked`: max(|dx|,|dy|) +
            // min(…)/2. Matches the metric used by the pathfinder cost,
            // so our seek stays consistent with the route it picks.
            @inline(__always)
            func packedDistance(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
                let dx = abs(ax - bx), dy = abs(ay - by)
                return max(dx, dy) + min(dx, dy) / 2
            }

            var radius1 = radius + 1         // best thin/thick within `radius`
            var radius2 = radius + 1         // best thick (d < 4) tracker
            var packed1: Int? = nil
            var packed2: Int? = nil

            for ty in ymin...ymax {
                for tx in xmin...xmax {
                    let tile = ty * 64 + tx
                    if structureOccupied.contains(tile) { continue }
                    if unitOccupied.contains(tile) { continue }
                    let level = map.cells[ty * SpiceMap.width + tx]
                    let isThick = (level == .thick)
                    let isThin = (level == .thin)
                    guard isThick || isThin else { continue }
                    let d = packedDistance(tx, ty, from.x, from.y)
                    if isThick, d < 4, d < radius2 {
                        radius2 = d; packed2 = tile
                    }
                    if d <= radius, d < radius1 {
                        radius1 = d; packed1 = tile
                    }
                }
            }
            // Thick within 4 wins; else nearest thin/thick inside radius.
            let chosen = packed2 ?? packed1
            guard let c = chosen else { return nil }
            return (c % 64, c / 64)
        }

        /// Slice 6b helper. Nearest same-house REFINERY for a full
        /// harvester. Uses squared-distance over the structure anchor
        /// tiles (close enough for routing; route cost lives in the
        /// pathfinder). Returns `nil` when the house owns no refinery.
        public static func findNearestRefinery(
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

        /// Slice 8a helper. Nearest same-house REFINERY whose chain
        /// is empty (`linkedID == 0xFF` — no harvester currently
        /// docked). Callers (tickHarvesting) prefer this over
        /// `findNearestRefinery` for full harvesters so two harvesters
        /// don't pile up at the same refinery while another sits idle.
        /// Returns nil when every refinery already has a docked
        /// harvester (or the house owns none); callers fall back to
        /// `findNearestRefinery` in that case.
        public static func findFreeRefinery(
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
                guard s.linkedID == 0xFF else { continue }
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

        /// Slice 8b helper. Count of same-house refineries (used in
        /// the scheduler to gate the carryall ferry on "house owns at
        /// least 2 refineries" — no point ferrying a single harvester
        /// to the same refinery it just left).
        static func countRefineries(
            houseID: UInt8, structures: StructurePool
        ) -> Int {
            var n = 0
            for idx in structures.findArray {
                let s = structures.slots[idx]
                if s.type == 12, s.houseID == houseID { n &+= 1 }
            }
            return n
        }

        /// Is this harvester currently chain-linked inside any refinery?
        /// "Docked" means `Structures.dockHarvester` wired the
        /// harvester into a refinery's `linkedID` chain and
        /// `undockHarvester` hasn't broken that link yet.
        ///
        /// This is the real anti-reharvest gate — `inTransport` can't
        /// serve that role because `harvestSpiceStep` sets
        /// `inTransport=true` on the very first successful pickup
        /// (port of OpenDUNE's `Script_Unit_Harvest`), so gating on
        /// `!inTransport` would let the harvester pick up exactly one
        /// unit and then freeze.
        ///
        /// Walks the `refinery.linkedID → harvester.linkedID → …`
        /// chain for every same-house refinery. Chains are typically
        /// length 1 — the safety valve caps at 8 hops.
        static func isHarvesterDocked(
            harvesterIndex: Int,
            structures: StructurePool,
            units: UnitPool
        ) -> Bool {
            guard harvesterIndex >= 0 else { return false }
            let target = UInt8(truncatingIfNeeded: harvesterIndex)
            for idx in structures.findArray {
                let s = structures.slots[idx]
                guard s.type == 12 /* REFINERY */ else { continue }
                var next = s.linkedID
                var hops = 0
                while next != 0xFF, hops < 8 {
                    if next == target { return true }
                    let uIdx = Int(next)
                    guard uIdx >= 0, uIdx < units.slots.count else { break }
                    next = units.slots[uIdx].linkedID
                    hops &+= 1
                }
            }
            return false
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

        /// Returns the refinery pool index whose footprint covers
        /// `tile` OR whose footprint is 4-adjacent to `tile`, else nil.
        ///
        /// Why adjacency: the pathfinder treats the 3×2 footprint as
        /// blocked (structures are impassable), so a harvester heading
        /// back to unload halts on a tile **next to** the refinery,
        /// never on top of it. OpenDUNE's `Unit_Move` fires
        /// `Unit_EnterStructure` when the moving unit's next tile is a
        /// structure tile — with our blocked-footprint pathfinder the
        /// unit can't reach a structure tile, so we accept the nearest
        /// adjacent tile as the dock trigger instead. Same observable
        /// behaviour: harvester arrives → dock → refinery state READY.
        static func refineryAtOrAdjacent(
            tile: (x: Int, y: Int),
            houseID: UInt8,
            structures: StructurePool
        ) -> Int? {
            if let idx = refineryAt(tile: tile, houseID: houseID, structures: structures) {
                return idx
            }
            let adjacents: [(Int, Int)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
            for (dx, dy) in adjacents {
                let cx = tile.x + dx
                let cy = tile.y + dy
                guard (0..<64).contains(cx), (0..<64).contains(cy) else { continue }
                if let idx = refineryAt(
                    tile: (x: cx, y: cy), houseID: houseID, structures: structures
                ) {
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
            self.unitOpcodeBudget = Self.unitOpcodesPerTick
            self.structureOpcodeBudget = Self.structureOpcodesPerTick
            self.teamOpcodeBudget = Self.teamOpcodesPerTick
        }

        /// Seeds per-entity `Scripting.Engine` state from a decoded save
        /// file so post-load script state picks up where the save paused,
        /// instead of getting clobbered by `VM.load(engine:typeID:)` on
        /// the first tick. Mirrors OpenDUNE's save-load flow: the save
        /// writes each `ScriptEngine`'s word-offset PC + stack + frame
        /// + variables + delay; on load, `scriptInfo` gets re-attached
        /// and execution resumes from the saved PC.
        ///
        /// Also seeds `loadedUnitAction / loadedStructureType /
        /// loadedTeamAction` so the first tick's delta-check sees "no
        /// change" and does NOT call `VM.load(...)` (which would reset
        /// the engine we just populated).
        ///
        /// Safe to call once, right after `init`, before the first
        /// `tick()`. Calling it mid-run is undefined — engines in
        /// flight would be clobbered.
        public mutating func seedFromSave(_ game: Formats.Save.Game) {
            for s in game.units.slots {
                let idx = Int(s.object.index)
                guard idx >= 0, idx < unitEngines.count else { continue }
                var engine = Scripting.Engine.fromSave(s.object.script)
                // OpenDUNE `src/saveload/unit.c:84` explicitly zeroes
                // `script.delay = 0` (and `timer = 0`) for every loaded
                // unit after decoding the save — so the first post-load
                // tick runs the script immediately regardless of the
                // saved delay. Preserving the saved delay leaves GUARD
                // units (e.g. SAVE007 u30, save-delay=11) frozen for 11
                // ticks before `Script_Unit_FindBestTarget` fires.
                engine.delay = 0
                unitEngines[idx] = engine
                loadedUnitAction[idx] = Int(s.actionID)
            }
            for s in game.structures.slots {
                let idx = Int(s.object.index)
                guard idx >= 0, idx < structureEngines.count else { continue }
                structureEngines[idx] = .fromSave(s.object.script)
                loadedStructureType[idx] = Int(s.object.type)
            }
            // TEAM chunk decoder is deferred (save-chunk TEAM decoder is
            // queued as P6 work per Plans/01.Initial.md §6 + queued item
            // in CurrentState.md); team engine seeding lands alongside it.
        }

        public mutating func tick() {
            // Fire-cooldown decrement runs first. `Script_Unit_Fire`
            // reads `fireDelay == 0` as its gate; decrementing before
            // the EMC dispatch matches OpenDUNE's `Unit_Tick` order.
            tickFireCooldowns()
            // Infantry walk-cycle animation advance.
            tickSpriteOffsets()
            // Explosion frame decrement — simple lifetime tick for the
            // presentation layer. Matches OpenDUNE's `Explosion_Tick`
            // reducing each active slot's `timeOut`, but simplified to
            // a single frame counter since we don't run the command
            // stream yet.
            tickExplosions()
            // Attack hold: stop an ACTION_ATTACK unit at its weapon's
            // fire range and snap orientation toward the target so
            // the fire gate can pass. Runs before `tickMovement` so
            // any movement cleared here doesn't produce a stale step
            // this tick. Parity harness disables this — real UNIT.EMC
            // runs the equivalent via `Script_Unit_MoveToTarget`.
            if tickAttackHoldEnabled { tickAttackHold() }
            // Route-follower runs BEFORE script dispatch so scripts (e.g.
            // `CalculateRoute`) observe the updated position when deciding
            // whether to pop the next step or re-plan.
            tickMovement()
            // Carryall arrival drop-off (slice 8c). tickMovement snaps
            // an in-transport carryall to its destination refinery and
            // clears `targetMove`; we pick that up here and detach the
            // harvester so its RETURN action can dock on the next
            // tickHarvesting pass.
            tickCarryallFerry()
            // Spice-bloom detonation — walks the unit pool once,
            // detonating any non-sandworm non-projectile unit standing
            // on a bloom tile. Port of OpenDUNE's `Unit_Move` bloom
            // check (`src/unit.c:1503`) without the per-step edge
            // walker: catches both "ordered to walk onto a bloom" and
            // "crossed a bloom mid-route" when the unit stops on it.
            tickBloomDetonation()
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
            // STARPORT passes. Delivery countdown runs at the faster
            // cadence (mirrors OpenDUNE's `tickStarport` at every 180
            // game ticks); availability-bump is the slower random
            // refresh (1800 game ticks in OpenDUNE).
            starportDeliveryTickCounter &+= 1
            if starportDeliveryTickCounter % Self.starportDeliveryCadenceTicks == 0 {
                tickStarportDelivery()
                // Immediately after the delivery pass spawns the
                // FRIGATE, unload its chain. OpenDUNE drives this via
                // FRIGATE.EMC's landing script (descent, per-unit
                // drop, takeoff). Our port does a scheduler-side
                // placement without the descent — units materialise
                // next to the pad.
                tickFrigateUnload()
            }
            starportAvailabilityTickCounter &+= 1
            if starportAvailabilityTickCounter % Self.starportAvailabilityCadenceTicks == 0 {
                tickStarportAvailability()
            }
            host.currentObject = nil
        }

        /// Attack-hold pass. OpenDUNE's UNIT.EMC handles this via per-
        /// tick range + orientation checks; our scripts run but don't
        /// reliably stop a non-turret attacker at fire range, and we
        /// don't have an `Orientation_Tick` rotator yet. Without
        /// either, a right-click attack has the attacker walk on top
        /// of its target and keep facing whichever direction it last
        /// moved in — so `Script_Unit_Fire`'s orientation gate never
        /// opens.
        ///
        /// For every used unit with `actionID == attack`, a valid
        /// `targetAttack`, and a resolvable target position:
        ///  - If within `fireDistance << 8` pixels: clear `targetMove`
        ///    / `currentDestination` / `route` so `tickMovement`
        ///    skips it this tick (the unit holds its tile).
        ///  - Snap `orientationCurrent` to the direction of the
        ///    target (no gradual rotation — a stand-in for the
        ///    deferred `turningSpeed` interpolator).
        /// Returns true when the encoded index resolves to a still-
        /// allocated unit / structure. Used by the attack-hold pass
        /// to detect "target just died" so the attacker can flip
        /// back to its default action. Tile-kind targets always
        /// read as alive (they reference a map position, not a
        /// pool slot).
        private static func isTargetAlive(
            encoded: Scripting.EncodedIndex, host: Scripting.Host
        ) -> Bool {
            switch encoded.kind {
            case .unit:
                let idx = Int(encoded.decoded)
                guard idx >= 0, idx < host.units.slots.count else { return false }
                return host.units.slots[idx].isUsed
            case .structure:
                let idx = Int(encoded.decoded)
                guard idx >= 0, idx < host.structures.slots.count else { return false }
                return host.structures.slots[idx].isUsed
            case .tile:
                return true  // tile targets don't "die".
            case .none:
                return false
            }
        }

        public mutating func tickAttackHold() {
            for idx in host.units.findArray {
                var slot = host.units.slots[idx]
                guard slot.isUsed else { continue }
                guard slot.actionID == Simulation.ActionID.attack else { continue }
                // Skip projectiles — they're ACTION_ATTACK units by
                // pool convention but the "hold + face target" rules
                // don't apply to bullets / missiles / sonic blasts.
                if Self.isProjectileType(slot.type) { continue }
                guard let info = Simulation.UnitInfo.lookup(slot.type) else { continue }
                // An ACTION_ATTACK with `targetAttack == 0` means the
                // caller is using ATTACK as a generic "move toward
                // tile and opportunistically fire" (same as OpenDUNE
                // HUNT scripts before they find a target). Leave those
                // alone — don't touch movement or action.
                guard slot.targetAttack != 0 else { continue }

                // targetAttack pointed at a unit / structure that got
                // freed → drop back to the unit's default action so
                // the attacker doesn't linger forever in ATTACK with
                // a stale encoded index. `actionsPlayer[3]` is the
                // GUARD / STOP fallback per OpenDUNE's
                // `Script_Unit_SetActionDefault` (src/script/unit.c:896).
                let encoded = Scripting.EncodedIndex(raw: slot.targetAttack)
                if !Self.isTargetAlive(encoded: encoded, host: host) {
                    let defaultAction = info.actionsPlayer[3]
                    let prior = slot.actionID
                    slot.actionID = defaultAction
                    slot.targetAttack = 0
                    slot.targetMove = 0
                    slot.currentDestinationX = 0
                    slot.currentDestinationY = 0
                    slot.route = [UInt8](repeating: 0xFF, count: 14)
                    host.units[idx] = slot
                    Log.info(
                        "attack-hold u\(idx) target-dead: action \(prior)→\(defaultAction), cleared move + target",
                        tracer: .label("attack-hold")
                    )
                    continue
                }
                guard let targetPos = Pos32.of(encoded, host: host) else { continue }
                let shooterPos = Pos32(x: slot.positionX, y: slot.positionY)
                let distance = UInt32(Pos32.distance(shooterPos, targetPos))
                let fireRange = UInt32(info.fireDistance) &<< 8
                // Face the target regardless of range (also gives
                // turreted units a sensible facing).
                let desired = Pos32.direction(from: shooterPos, to: targetPos)
                let priorOrient = slot.orientationCurrent
                slot.orientationCurrent = Int8(bitPattern: desired)
                // Within fire range: halt approach.
                var cleared = false
                if distance <= fireRange {
                    if slot.targetMove != 0
                        || slot.currentDestinationX != 0 || slot.currentDestinationY != 0
                        || slot.route[0] != 0xFF
                    {
                        slot.targetMove = 0
                        slot.currentDestinationX = 0
                        slot.currentDestinationY = 0
                        slot.route = [UInt8](repeating: 0xFF, count: 14)
                        cleared = true
                    }
                }
                host.units[idx] = slot
                if cleared || priorOrient != slot.orientationCurrent {
                    Log.debug(
                        "attack-hold u\(idx) dist=\(distance) fireRange=\(fireRange) orient=\(priorOrient)→\(slot.orientationCurrent) cleared=\(cleared)",
                        tracer: .label("attack-hold")
                    )
                }
            }
        }

        /// Spice-bloom detonation pass. For every used unit that is
        /// not a SANDWORM or projectile and whose current tile's
        /// landscape is `.bloomField`, triggers
        /// `Simulation.Bloom.explodeSpice` — spawns a tremor
        /// explosion, fills a radius-5 spice circle, resets the cell
        /// to sand, and frees the walking unit. Requires
        /// `host.landscapeAt` + `host.groundTileOverride` + a cached
        /// `sandTileID` (the first sprite in the landscape iconGroup)
        /// from the scheduler's `bloomSandTileID` field.
        ///
        /// `bloomSandTileID == 0` disables the pass entirely — tests
        /// that don't care about blooms can leave it zero.
        public mutating func tickBloomDetonation() {
            guard bloomSandTileID != 0 else { return }
            guard let landscapeAt = host.landscapeAt else { return }
            let rng: () -> UInt8 = harvestRNG ?? { 0 }
            let bloomByte = UInt8(LandscapeType.bloomField.rawValue)
            // Snapshot findArray — Bloom.explodeSpice frees the unit
            // in-place, which mutates findArray mid-iteration.
            let snapshot = host.units.findArray
            for idx in snapshot {
                guard idx < host.units.slots.count else { continue }
                let u = host.units.slots[idx]
                guard u.isUsed else { continue }
                if u.type == 25 /* SANDWORM */ { continue }
                if Self.isProjectileType(u.type) { continue }
                let tx = Int(u.positionX) / 256
                let ty = Int(u.positionY) / 256
                guard (0..<64).contains(tx), (0..<64).contains(ty) else { continue }
                let packed = UInt16(ty * 64 + tx)
                if landscapeAt(packed) != bloomByte { continue }
                Simulation.Bloom.explodeSpice(
                    packed: packed,
                    unitIndex: idx,
                    sandTileID: bloomSandTileID,
                    host: host,
                    rng: rng
                )
            }
        }

        // MARK: - STARPORT slice 5b — delivery + availability-refresh passes

        /// Per-house delivery countdown. Port of OpenDUNE's
        /// `tickStarport` block in `GameLoop_House` (`src/house.c:219..258`).
        /// For each allocated house with a live `starportLinkedID`:
        ///
        /// 1. Decrement `starportTimeLeft`; clamp at 0 (underflow guard
        ///    — OpenDUNE uses `(int16)h->starportTimeLeft < 0 → 0`).
        /// 2. On reaching 0, look up one of the house's STARPORT
        ///    structures and spawn a `UNIT_FRIGATE` via
        ///    `Units.createUnit` (type 27 — see `UnitType.frigate`).
        ///    Move the waiting unit-chain onto the frigate (`u.linkedID
        ///    = h.starportLinkedID`), clear `h.starportLinkedID`, flip
        ///    `u.inTransport = true`.
        /// 3. Reseed `starportTimeLeft` (`starportDeliveryTimeByHouse`
        ///    on successful spawn; `1` to retry next tick otherwise).
        ///
        /// Only fires when at least one STARPORT of the house is
        /// present; without one, the countdown still runs (so the chain
        /// is never orphaned on demolish) but the frigate spawn is
        /// skipped and the timer resets to 1.
        public mutating func tickStarportDelivery() {
            for houseIdx in host.houses.findArray {
                var h = host.houses.slots[houseIdx]
                guard h.isUsed else { continue }
                if h.starportLinkedID == HousePool.invalidIndex { continue }
                // Underflow-safe decrement.
                if h.starportTimeLeft > 0 { h.starportTimeLeft -= 1 }
                guard h.starportTimeLeft == 0 else {
                    host.houses[houseIdx] = h
                    continue
                }
                // Find the first STARPORT (type 11) owned by this house
                // that isn't already ferrying a delivery.
                let houseID = UInt8(truncatingIfNeeded: houseIdx)
                var frigateIdx: Int? = nil
                for sIdx in host.structures.findArray {
                    let s = host.structures.slots[sIdx]
                    guard s.isUsed, s.type == 11 /* STARPORT */, s.houseID == houseID else { continue }
                    // OpenDUNE skips starports whose `linkedID != 0xFF` —
                    // they already have a frigate in flight.
                    if s.linkedID != 0xFF { continue }
                    // Spawn a frigate (`UNIT_FRIGATE` = 26) at the
                    // structure centre; the actual landing animation is
                    // a script concern to be wired later.
                    let fidx = Simulation.Units.createUnit(
                        type: 26 /* FRIGATE */, houseID: houseID,
                        tileX: Int(s.positionX) / 256, tileY: Int(s.positionY) / 256,
                        pool: &host.units
                    )
                    if let fidx = fidx {
                        frigateIdx = fidx
                        // Move the waiting chain onto the frigate.
                        var f = host.units[fidx]
                        f.linkedID = UInt8(truncatingIfNeeded: h.starportLinkedID & 0xFF)
                        f.inTransport = true
                        host.units[fidx] = f
                        h.starportLinkedID = HousePool.invalidIndex
                    }
                    break
                }
                h.starportTimeLeft = (frigateIdx != nil)
                    ? Self.starportDeliveryTimeByHouse[houseIdx]
                    : 1
                host.houses[houseIdx] = h
                Log.info(
                    "tickStarportDelivery house=\(houseIdx) frigate=\(frigateIdx.map(String.init) ?? "none") timeLeft→\(h.starportTimeLeft)",
                    tracer: .label("starport")
                )
            }
        }

        /// Port of OpenDUNE's `tickStarportAvailability` block at
        /// `src/house.c:101..115`. Every `starportAvailabilityCadenceTicks`
        /// picks a random unit type and bumps the global stock:
        ///
        /// - `stock == 0`  → leave (type is simply not for sale here).
        /// - `stock == -1` → set to 1 (first frigate discovers stock).
        /// - `stock in 1..9` → increment (frigates bring more).
        /// - `stock >= 10` → cap (OpenDUNE's cap; keeps CHOAM stock
        ///   bounded).
        ///
        /// Gated on `harvestRNG` availability (we reuse the same
        /// `Tools_Random_256` port — no separate starport RNG needed).
        public mutating func tickStarportAvailability() {
            guard let rng = harvestRNG else { return }
            // Draw a type in 0..26 (UNIT_MAX-1 in OpenDUNE terms).
            let type = Int(rng()) % starportStock.count
            let stock = starportStock[type]
            guard stock != 0, stock < 10 else { return }
            starportStock[type] = (stock == -1) ? 1 : stock + 1
            Log.debug(
                "tickStarportAvailability type=\(type) \(stock)→\(starportStock[type])",
                tracer: .label("starport")
            )
        }

        /// STARPORT slice 5b follow-up — frigate-unload pass. Fires
        /// right after `tickStarportDelivery`. For every spawned
        /// FRIGATE that still carries a linked-unit chain, walks the
        /// chain, drops each unit on a passable adjacent tile of the
        /// STARPORT, clears `inTransport`, and frees the frigate slot
        /// once the chain is empty.
        ///
        /// OpenDUNE drives this via FRIGATE.EMC (descent → per-unit
        /// drop → takeoff); the landing animation itself is purely
        /// cosmetic and lives in the script. Our port fast-forwards
        /// the mechanical half — units arrive around the pad — and
        /// defers the visual descent until the EMC port lands.
        public mutating func tickFrigateUnload() {
            // Snapshot findArray — `units.free` mutates it mid-loop.
            let snapshot = host.units.findArray
            for fidx in snapshot {
                guard fidx < host.units.slots.count else { continue }
                let f = host.units.slots[fidx]
                guard f.isUsed, f.type == 26 /* FRIGATE */ else { continue }
                guard f.inTransport, f.linkedID != 0xFF else { continue }
                // Frigate must be at a same-house STARPORT's pad; our
                // tickStarportDelivery spawns it directly on the
                // structure anchor, so the check is straightforward.
                let fx = Int(f.positionX) / 256
                let fy = Int(f.positionY) / 256
                guard let starport = nearestStarport(
                    forHouse: f.houseID, nearTile: (fx, fy)
                ) else { continue }
                let sx = Int(starport.positionX) / 256
                let sy = Int(starport.positionY) / 256

                // Drop every chained unit on a free adjacent tile of
                // the STARPORT footprint (3×3). Breaks the chain
                // one link at a time so a partial drop (no more free
                // tiles) leaves the remaining units on the frigate
                // for a later retry — matching OpenDUNE's "try again
                // next tick" semantic.
                var chainHead = Int(f.linkedID)
                var dropped = 0
                let candidates = starportAdjacentTiles(anchor: (sx, sy))
                var available = candidates
                while chainHead != 0xFF, !available.isEmpty {
                    guard chainHead < host.units.slots.count else { break }
                    var cargo = host.units.slots[chainHead]
                    guard cargo.isUsed else { break }
                    // Pick the first tile that's passable for this
                    // unit's movement type. OpenDUNE's frigate drops
                    // at fixed offsets; we're looser — any passable
                    // ring tile works.
                    let mt = Simulation.UnitInfo.lookup(cargo.type)?.movementType ?? .foot
                    guard let tile = available.first(where: {
                        isTilePassable(tileX: $0.0, tileY: $0.1, movementType: mt)
                    }) else { break }
                    available.removeAll { $0 == tile }
                    let nextLink = cargo.linkedID
                    cargo.positionX = UInt16(tile.0 * 256 + 128)
                    cargo.positionY = UInt16(tile.1 * 256 + 128)
                    cargo.inTransport = false
                    cargo.linkedID = 0xFF
                    host.units[chainHead] = cargo
                    Log.info(
                        "frigate-unload frigate=\(fidx) cargo=\(chainHead) (type \(cargo.type)) → tile=(\(tile.0),\(tile.1))",
                        tracer: .label("starport")
                    )
                    chainHead = Int(nextLink)
                    dropped += 1
                }

                // Re-write the frigate's remaining chain head (or
                // clear it when everything dropped).
                var newFrigate = host.units.slots[fidx]
                newFrigate.linkedID = UInt8(truncatingIfNeeded: chainHead & 0xFF)
                host.units[fidx] = newFrigate
                if newFrigate.linkedID == 0xFF {
                    Log.info(
                        "frigate-unload frigate=\(fidx) chain drained after \(dropped) drops — freeing",
                        tracer: .label("starport")
                    )
                    host.units.free(at: fidx)
                }
            }
        }

        /// Ring of 12 tiles immediately outside a 3×3 STARPORT's
        /// footprint — 4 edges × 3 tiles, corners excluded (corners
        /// touch two footprint tiles and are awkward to path into).
        private func starportAdjacentTiles(
            anchor: (x: Int, y: Int)
        ) -> [(Int, Int)] {
            var ring: [(Int, Int)] = []
            // North + south edges.
            for dx in 0..<3 {
                ring.append((anchor.x + dx, anchor.y - 1))
                ring.append((anchor.x + dx, anchor.y + 3))
            }
            // East + west edges.
            for dy in 0..<3 {
                ring.append((anchor.x - 1, anchor.y + dy))
                ring.append((anchor.x + 3, anchor.y + dy))
            }
            // Clamp to map bounds.
            return ring.filter { (0..<64).contains($0.0) && (0..<64).contains($0.1) }
        }

        /// Nearest STARPORT (type 11) owned by `houseID` by
        /// squared-distance from `nearTile`. Returns nil when the
        /// house has no STARPORT.
        private func nearestStarport(
            forHouse houseID: UInt8, nearTile: (x: Int, y: Int)
        ) -> Simulation.StructureSlot? {
            var best: (slot: Simulation.StructureSlot, d2: Int)?
            for idx in host.structures.findArray {
                let s = host.structures.slots[idx]
                guard s.isUsed, s.type == 11, s.houseID == houseID else { continue }
                let sx = Int(s.positionX) / 256
                let sy = Int(s.positionY) / 256
                let dx = sx - nearTile.x
                let dy = sy - nearTile.y
                let d2 = dx * dx + dy * dy
                if best == nil || d2 < best!.d2 {
                    best = (s, d2)
                }
            }
            return best?.slot
        }

        /// Carryall arrival pass (slice 8c). Walks the unit pool once
        /// and, for every in-transport CARRYALL whose `targetMove`
        /// just cleared (tickMovement's arrival signal), calls
        /// `Simulation.Units.dropCarryall` to detach the ferried
        /// harvester + free the carryall slot.
        ///
        /// Arrival detection is the transition `targetMove != 0 →
        /// targetMove == 0` that tickMovement writes on arrival at a
        /// target-move tile (see `Scheduler.swift:tickMovement` →
        /// "Arrived via targetMove fallback"). Carryalls that didn't
        /// have a targetMove to begin with (idle slots, legacy state)
        /// are skipped by the `inTransport && linkedID != 0xFF`
        /// filter.
        public mutating func tickCarryallFerry() {
            for idx in host.units.findArray {
                let carryall = host.units.slots[idx]
                guard carryall.isUsed else { continue }
                guard carryall.type == 0 /* CARRYALL */ else { continue }
                guard carryall.inTransport else { continue }
                guard carryall.linkedID != 0xFF else { continue }
                guard carryall.targetMove == 0 else { continue }
                _ = Simulation.Units.dropCarryall(
                    carryallIndex: idx,
                    units: &host.units,
                    structures: host.structures
                )
            }
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

            // Harvester AI transitions (slices 6b + 7):
            // - HARVEST + amount>=100 + not docked → seek nearest
            //   same-house refinery, issue move, flip to RETURN.
            // - RETURN + on a refinery footprint → dockHarvester,
            //   flip back to HARVEST.
            // - HARVEST + amount<100 + not docked + no active move +
            //   standing off-spice → find nearest spice tile + orderMove
            //   (slice 7). Closes the cycle after undock so harvesters
            //   resume working without a human nudge.
            for idx in host.units.findArray {
                var slot = host.units.slots[idx]
                guard slot.type == 16 else { continue }
                // Physical dock check replaces `!inTransport` gates on
                // every branch below — `inTransport` flips to true on
                // the first successful `harvestSpiceStep` (port of
                // OpenDUNE's `Script_Unit_Harvest` which uses it as a
                // "has cargo" flag), so guarding on `!inTransport` used
                // to short-circuit the loop after a single pickup.
                // The true "don't touch this harvester" signal is
                // whether it's currently chain-linked to a refinery.
                let isDocked = Self.isHarvesterDocked(
                    harvesterIndex: idx,
                    structures: host.structures,
                    units: host.units
                )
                // Harvester action coherence pin. OpenDUNE's
                // `Script_Unit_Harvest` (`src/script/unit.c:1640..1669`)
                // returns 0 when `amount >= 100` — that's the sole
                // "I'm full" signal the EMC script uses to transition
                // to RETURN via `Script_Unit_GoToClosestStructure`.
                // Since slot 0x2A is not yet ported (halts on call),
                // the EMC script can flip action to bogus values
                // (GUARD / ATTACK / ambush) and strand a half-loaded
                // harvester. The pin defends against those drifts
                // without stealing the harvest/return/move/stop trio's
                // organic transitions (which our own branches below
                // handle correctly).
                //
                // `.stop` is treated as ORGANIC: a harvester that
                // arrives via a player-ordered `orderMove` flips
                // through the UNIT.EMC MOVE script to
                // `actionsPlayer[3]` (= `.stop` for HARVESTER) on
                // arrival. Respecting that means manual moves halt
                // the harvester instead of auto-resuming the seek
                // cycle. The player must press `H` (or right-click
                // spice, which `orderHarvest` maps to `action=.harvest`)
                // to explicitly resume auto-harvest.
                //
                // Exception: `.stop` + `amount >= 100` flips to
                // `.returnAction` — a full harvester still needs to
                // deposit regardless of what sent it to stop, so we
                // override this case so the user doesn't have to
                // hand-pilot full harvesters back to a refinery.
                //
                // Rule:
                //   {.harvest, .returnAction, .move, .stop} → leave
                //     alone (organic); the branches below own these.
                //   .stop + full                          → flip to
                //     .returnAction (auto-return when loaded).
                //   other non-organic + idle              → override:
                //     .returnAction if amount≥100, else .harvest.
                //   RETURN + idle + amount<100            → demote to
                //     .harvest (EMC-driven bogus-RETURN case that
                //     strands a partly-loaded harvester off spice).
                let idleState = slot.targetMove == 0
                    && slot.route[0] == 0xFF
                    && slot.currentDestinationX == 0
                    && slot.currentDestinationY == 0
                let isOrganicAction = slot.actionID == Simulation.ActionID.harvest
                    || slot.actionID == Simulation.ActionID.returnAction
                    || slot.actionID == Simulation.ActionID.move
                    || slot.actionID == Simulation.ActionID.stop
                if !isDocked, slot.actionID == Simulation.ActionID.stop,
                   slot.amount >= 100, idleState
                {
                    slot.actionID = Simulation.ActionID.returnAction
                    host.units[idx] = slot
                    Log.info(
                        "harvest-pin harvester=\(idx) STOP → RETURN (full, idle) amount=\(slot.amount)",
                        tracer: .label("harvest-tick")
                    )
                } else if !isDocked, !isOrganicAction, idleState {
                    let prior = slot.actionID
                    slot.actionID = slot.amount >= 100
                        ? Simulation.ActionID.returnAction
                        : Simulation.ActionID.harvest
                    host.units[idx] = slot
                    Log.info(
                        "harvest-pin harvester=\(idx) \(prior) → \(slot.actionID) (idle, amount=\(slot.amount))",
                        tracer: .label("harvest-tick")
                    )
                }
                if !isDocked, slot.actionID == Simulation.ActionID.returnAction,
                   slot.amount < 100, idleState
                {
                    // Bogus EMC-driven RETURN at amount<100 with no
                    // active plan — strands the harvester on whatever
                    // tile it halted on. Demote to HARVEST so the
                    // seek-spice branch fires on this tick.
                    slot.actionID = Simulation.ActionID.harvest
                    host.units[idx] = slot
                    Log.info(
                        "harvest-pin harvester=\(idx) RETURN → HARVEST (idle, amount=\(slot.amount) < 100, bogus)",
                        tracer: .label("harvest-tick")
                    )
                }
                if slot.actionID == Simulation.ActionID.harvest,
                   slot.amount >= 100, !isDocked
                {
                    // Slice 8a: prefer a free refinery (no harvester
                    // docked) over the absolute nearest so two
                    // harvesters parallelise across refineries
                    // instead of queueing at the closer one.
                    // Slice 8b: if every refinery is busy AND the
                    // house owns at least two refineries (so a ferry
                    // actually has somewhere to go), call a carryall
                    // to lift this harvester out to the nearest one
                    // rather than make it trundle over on foot.
                    let freeIdx = Self.findFreeRefinery(
                        forHarvester: slot, structures: host.structures
                    )
                    if let freeIdx {
                        let r = host.structures.slots[freeIdx]
                        let rx = Int(r.positionX) / 256
                        let ry = Int(r.positionY) / 256
                        _ = Simulation.Units.orderMove(
                            poolIndex: idx, tileX: rx, tileY: ry, units: &host.units
                        )
                        var u = host.units[idx]
                        u.actionID = Simulation.ActionID.returnAction
                        host.units[idx] = u
                        Log.info(
                            "harvest-cycle full harvester=\(idx) → refinery=\(freeIdx) (free) tile=(\(rx),\(ry))",
                            tracer: .label("harvest-tick")
                        )
                    } else if Self.countRefineries(
                        houseID: slot.houseID, structures: host.structures
                    ) >= 2,
                    let nearestBusy = Self.findNearestRefinery(
                        forHarvester: slot, structures: host.structures
                    ) {
                        _ = Simulation.Units.callCarryall(
                            harvesterIndex: idx,
                            destinationRefineryIndex: nearestBusy,
                            units: &host.units,
                            structures: host.structures
                        )
                        var u = host.units[idx]
                        u.actionID = Simulation.ActionID.returnAction
                        host.units[idx] = u
                        Log.info(
                            "harvest-cycle full harvester=\(idx) → carryall ferry (all-busy)",
                            tracer: .label("harvest-tick")
                        )
                    } else if let refIdx = Self.findNearestRefinery(
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
                            "harvest-cycle full harvester=\(idx) → refinery=\(refIdx) (only-option) tile=(\(rx),\(ry))",
                            tracer: .label("harvest-tick")
                        )
                    }
                } else if slot.actionID == Simulation.ActionID.harvest,
                          slot.amount < 100, !isDocked
                {
                    let hx = Int(slot.positionX) / 256
                    let hy = Int(slot.positionY) / 256
                    // Idle when not already moving AND current tile is
                    // not spice (can't harvest where we stand).
                    let idle = slot.targetMove == 0
                        && slot.route[0] == 0xFF
                        && slot.currentDestinationX == 0
                        && slot.currentDestinationY == 0
                    let currentPacked = UInt16(hy * 64 + hx)
                    let onSpice: Bool = {
                        let lb = spiceMap.landscapeByte(at: currentPacked)
                        return lb == UInt8(LandscapeType.spice.rawValue)
                            || lb == UInt8(LandscapeType.thickSpice.rawValue)
                    }()
                    if idle, !onSpice,
                       let spice = Self.findSpiceNear(
                           from: (x: hx, y: hy),
                           radius: Self.autoHarvestSpiceSearchRadius,
                           playableRect: playableRect,
                           map: spiceMap,
                           structures: host.structures,
                           units: host.units,
                           excludingUnit: idx
                       )
                    {
                        _ = Simulation.Units.orderMove(
                            poolIndex: idx, tileX: spice.x, tileY: spice.y,
                            units: &host.units
                        )
                        Log.info(
                            "harvest-cycle seek-spice harvester=\(idx) from=(\(hx),\(hy)) → tile=(\(spice.x),\(spice.y))",
                            tracer: .label("harvest-tick")
                        )
                    }
                } else if slot.actionID == Simulation.ActionID.returnAction,
                          !isDocked
                {
                    let tx = Int(slot.positionX) / 256
                    let ty = Int(slot.positionY) / 256
                    if let refIdx = Self.refineryAtOrAdjacent(
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
                    } else {
                        // RETURN with no active move = re-plan. Port of
                        // OpenDUNE's `Script_Unit_GoToClosestStructure`
                        // (`src/script/unit.c:1786`): find nearest
                        // same-house refinery, issue move, keep RETURN
                        // action so the next dock check fires when we
                        // arrive. Without this the EMC HARVEST script's
                        // SetAction(RETURN) branch — fired whenever our
                        // nil `Script_Unit_Harvest` slot trips the
                        // script's "harvest failed" branch — strands the
                        // harvester on whatever tile it last halted on.
                        let idle = slot.targetMove == 0
                            && slot.route[0] == 0xFF
                            && slot.currentDestinationX == 0
                            && slot.currentDestinationY == 0
                        if idle,
                           let refIdx = Self.findFreeRefinery(
                               forHarvester: slot, structures: host.structures
                           ) ?? Self.findNearestRefinery(
                               forHarvester: slot, structures: host.structures
                           )
                        {
                            let r = host.structures.slots[refIdx]
                            let rx = Int(r.positionX) / 256
                            let ry = Int(r.positionY) / 256
                            _ = Simulation.Units.orderMove(
                                poolIndex: idx, tileX: rx, tileY: ry,
                                units: &host.units
                            )
                            // orderMove flips action to .move; restore
                            // RETURN so the arrival-dock branch fires.
                            var u = host.units[idx]
                            u.actionID = Simulation.ActionID.returnAction
                            host.units[idx] = u
                            Log.info(
                                "harvest-cycle RETURN replan harvester=\(idx) → refinery=\(refIdx) tile=(\(rx),\(ry))",
                                tracer: .label("harvest-tick")
                            )
                        }
                    }
                }
            }

            // Harvest pass.
            for idx in host.units.findArray {
                let slot = host.units.slots[idx]
                guard slot.type == 16 /* HARVESTER */ else { continue }
                guard slot.actionID == Simulation.ActionID.harvest else { continue }
                // Skip docked harvesters — they're being refined, not
                // harvesting. `inTransport` alone is unreliable (port
                // of OpenDUNE's `Script_Unit_Harvest` sets it to true
                // on the first successful pickup) — a docked-chain
                // check is the authoritative gate.
                if Self.isHarvesterDocked(
                    harvesterIndex: idx,
                    structures: host.structures,
                    units: host.units
                ) { continue }
                let before = slot.amount
                // Slice 9: when `apply` transitions a cell between
                // bare / thin / thick, fire the host's repaint
                // notifier so `ScenarioRuntime` can rewrite the
                // matching `tileGrid.groundTileID` and the scene /
                // minimap / screenshot see the drain in real time.
                let notifier = host.spiceLevelDidChange
                _ = Simulation.Units.harvestSpiceStep(
                    harvesterIndex: idx,
                    units: &host.units,
                    landscapeAt: { spiceMap.landscapeByte(at: $0) },
                    changeSpice: { packed, delta in
                        let levelBefore = spiceMap[packed]
                        let levelAfter = spiceMap.apply(delta: delta, at: packed)
                        if levelBefore != levelAfter { notifier?(packed, levelAfter, spiceMap) }
                    },
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

        /// Advances the infantry walk-cycle animation frame by bumping
        /// `spriteOffset` once every 5 scheduler ticks. Mirrors
        /// OpenDUNE's `src/unit.c:243..244`:
        /// `u->spriteOffset = (u->spriteOffset & 0x3F) + 1;` — a
        /// six-bit counter that's sampled with `& 3` by the infantry
        /// resolver to produce a 4-phase cycle. Only infantry (3/4-frame
        /// display modes) are animated; vehicles leave the byte alone.
        /// Gated by `spriteAnimationStride` so the walk cycle plays at
        /// a reasonable visual pace.
        public static let spriteAnimationStride = 5
        private mutating func tickSpriteOffsets() {
            guard spriteAnimationCounter % Self.spriteAnimationStride == 0 else {
                spriteAnimationCounter &+= 1
                return
            }
            spriteAnimationCounter &+= 1
            for idx in host.units.findArray {
                var slot = host.units.slots[idx]
                guard let info = Simulation.UnitInfo.lookup(slot.type) else { continue }
                switch info.displayMode {
                case .infantry3, .infantry4:
                    // OpenDUNE `src/unit.c:241`: animation advances only
                    // when `(movementType == MOVEMENT_FOOT && u->speed != 0)
                    // || u->o.flags.s.isSmoking`. `u->speed` is the tile-hop
                    // clamp that `Unit_SetSpeed` writes — non-zero iff the
                    // unit is actually mid-move. A parked HUNT trooper
                    // with a stale `targetMove` pointing at a distant
                    // enemy still has `speed == 0` and must NOT animate
                    // (SAVE007 unit[25]). `isSmoking` isn't on our slots
                    // yet; land it alongside explosion-damage flagging.
                    guard slot.speed != 0 else { continue }
                    // `spriteOffset < 0` is OpenDUNE's "don't animate"
                    // marker for specific states (spawning, dying); skip.
                    guard slot.spriteOffset >= 0 else { continue }
                    let bumped = (UInt8(bitPattern: slot.spriteOffset) & 0x3F) &+ 1
                    slot.spriteOffset = Int8(bitPattern: bumped)
                    host.units[idx] = slot
                default:
                    continue
                }
            }
        }
        private var spriteAnimationCounter: Int = 0

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
                       !isTilePassable(tileX: tileX, tileY: tileY, movementType: mt, excludingUnit: idx)
                    {
                        // Clear the route but KEEP `targetMove` so the
                        // next UNIT.EMC tick re-runs CalculateRoute and
                        // replans around whatever's now sitting on the
                        // planned step (typically a transient — another
                        // unit crossing the path). Without this, two
                        // hunt-action enemies whose routes cross wedge
                        // each other into concave building angles and
                        // never recover.
                        Log.info(
                            "move-halt u\(idx) impassable tile=(\(tileX),\(tileY)) mt=\(mt) — clearing route, keeping targetMove=\(String(format: "0x%04X", slot.targetMove)) for replan",
                            tracer: .label("move")
                        )
                        slot.route = [UInt8](repeating: 0xFF, count: 14)
                        slot.currentDestinationX = 0
                        slot.currentDestinationY = 0
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
                    // non-tracked, walls, structures). When the target
                    // tile itself is impassable, redirect to the
                    // nearest passable adjacent tile so hunt-action
                    // enemies stop adjacent to their target (a CYARD,
                    // a wall, …) instead of halting at spawn.
                    var goalTileX = Int(t.x) / 256
                    var goalTileY = Int(t.y) / 256
                    var adjusted = t
                    let mt = Simulation.UnitInfo.lookup(slot.type)?.movementType ?? .foot
                    if !Self.isProjectileType(slot.type),
                       !isTilePassable(tileX: goalTileX, tileY: goalTileY, movementType: mt, excludingUnit: idx)
                    {
                        if let nearest = nearestPassableNeighbor(
                            of: (goalTileX, goalTileY),
                            from: (Int(slot.positionX) / 256, Int(slot.positionY) / 256),
                            movementType: mt
                        ) {
                            goalTileX = nearest.0
                            goalTileY = nearest.1
                            adjusted = Pos32(
                                x: UInt16(clamping: goalTileX * 256 + 128),
                                y: UInt16(clamping: goalTileY * 256 + 128)
                            )
                            Log.debug(
                                "move-retarget u\(idx) target impassable → adjacent tile=(\(goalTileX),\(goalTileY))",
                                tracer: .label("move")
                            )
                        } else {
                            Log.info(
                                "move-halt u\(idx) fallback target=(\(goalTileX),\(goalTileY)) impassable mt=\(mt) — clearing",
                                tracer: .label("move")
                            )
                            slot.targetMove = 0
                            host.units[idx] = slot
                            continue
                        }
                    }
                    goal = adjusted
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

                // `Tile_GetDistance` semantics (`max(|dx|,|dy|) + min/2`).
                // Used both for the arrival threshold and the
                // per-trigger distance cap — matches OpenDUNE's
                // `Unit_MovementTick` distance arg. We also keep this
                // value to detect overshoot: a post-move distance
                // GREATER than the pre-move distance means we've
                // stepped past the goal (per `unit.c:1419`'s
                // `distanceToDestination < distance` test).
                let here = Pos32(x: slot.positionX, y: slot.positionY)
                let distBefore = Int32(Pos32.distance(here, goal))
                let distToGoal = distBefore

                if distToGoal <= arrivalThreshold {
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

                // Orientation first: the subpixel step uses
                // `orientation[0].current` to pick the `_stepX/_stepY`
                // direction, so it must be set before we move.
                //   - Route-driven step: lock to `route[0] * 32`
                //     (octant midpoint). The pathfinder produces octant
                //     indices; the sprite locks to those even if the
                //     pos32 delta to `currentDestination` wouldn't
                //     exactly match.
                //   - targetMove fallback: recompute the continuous
                //     heading toward the goal.
                //   - `currentDestination` set but no route: DO NOT
                //     touch orientation. OpenDUNE's `Unit_MovementTick`
                //     never recomputes orientation — the script sets
                //     it (e.g. `Unit_SetOrientation`) before any
                //     movement tick runs. Wingers whose scripts set a
                //     direct pos32 destination + orientation are the
                //     load-bearing case; recomputing from pos→dest
                //     would flip their heading 180° on a unit that's
                //     just past the destination for a fly-through,
                //     which was the tick-parity SAVE007 tick-1 bug
                //     (`unit[0].positionX` drift).
                let priorOrient = slot.orientationCurrent
                // Orientation recompute is gated on `speed != 0`. OpenDUNE's
                // `Unit_MovementTick` (`src/unit.c:98`) early-returns at
                // `speed == 0` and never touches orientation for parked
                // units. Our fallback-slide recompute used to fire for
                // parked HUNT troopers whose targetMove pointed at a
                // blocked tile — the `nearestPassableNeighbor` redirect
                // picked an adjacent tile that happens to be in the
                // wrong direction (SAVE007 unit[25] parked east-facing,
                // targetMove on unit 26 blocked by a refinery, redirect
                // to a north-side neighbor → our code rotated the unit
                // north on tick 1 while OpenDUNE kept it east).
                if slot.speed != 0 {
                    if goalSource == "route", slot.route[0] != 0xFF {
                        slot.orientationCurrent = Int8(bitPattern: slot.route[0] &* 32)
                    } else if goalSource == "targetMove(fallback)" {
                        let from = Pos32(x: slot.positionX, y: slot.positionY)
                        slot.orientationCurrent = Int8(bitPattern: Pos32.direction(from: from, to: goal))
                    }
                }
                // else: keep stored orientation (script-set).

                // Subpixel movement — port of OpenDUNE's
                // `Unit_MovementTick` (`src/unit.c:98`). speed is the
                // per-trigger pixel clamp (`speed * 16`, capped by
                // distance-to-destination + 16); speedPerTick is the
                // per-tick accumulator increment; speedRemainder is the
                // fractional-pixel carry. When the accumulator
                // overflows past 255, a step fires via
                // `Pos32.moved(...)` along the orientation vector.
                let priorX = slot.positionX
                let priorY = slot.positionY
                var didStep = false
                if slot.speed != 0, slot.speedPerTick != 0 {
                    // Match OpenDUNE `Unit_MovementTick` (`src/unit.c:107`):
                    // ground units feel gameSpeed on the per-tick
                    // increment; wingers add `speedPerTick` raw.
                    let mt = Simulation.UnitInfo.lookup(slot.type)?.movementType
                    let increment: UInt16
                    if mt != .winger {
                        increment = Simulation.Tools.adjustToGameSpeed(
                            normal: UInt16(slot.speedPerTick),
                            minimum: 1, maximum: 255,
                            inverseSpeed: false, gameSpeed: gameSpeed
                        )
                    } else {
                        increment = UInt16(slot.speedPerTick)
                    }
                    let remainder = UInt16(slot.speedRemainder) &+ increment
                    slot.speedRemainder = UInt8(truncatingIfNeeded: remainder & 0xFF)
                    if (remainder & 0xFF00) != 0 {
                        // `distance` in pos32 pixels: min(speed*16, dist+16).
                        let capBySpeed = UInt32(slot.speed) * 16
                        let capByGoal = UInt32(distToGoal) + 16
                        let distance = UInt32(min(capBySpeed, capByGoal))
                        let orient = UInt8(bitPattern: slot.orientationCurrent)
                        let from = Pos32(x: slot.positionX, y: slot.positionY)
                        let next = Pos32.moved(
                            from, orientation: orient, distance: distance
                        )
                        // Fallback-slide obstacle gate. The route-step
                        // branch validates the next tile before picking
                        // it up (~L1003), but a fallback slide flies
                        // straight at `targetMove` with no intermediate
                        // checks — so a building between start and goal
                        // gets clipped unless we re-check the tile
                        // we're about to enter. Halt and keep
                        // `targetMove` so the script's `CalculateRoute`
                        // replans around it on its next dispatch.
                        if goalSource != "route", !Self.isProjectileType(slot.type) {
                            let oldTX = Int(from.x) / 256
                            let oldTY = Int(from.y) / 256
                            let newTX = Int(next.x) / 256
                            let newTY = Int(next.y) / 256
                            if (newTX != oldTX || newTY != oldTY) {
                                let mt = Simulation.UnitInfo.lookup(slot.type)?.movementType ?? .foot
                                if !isTilePassable(tileX: newTX, tileY: newTY, movementType: mt, excludingUnit: idx) {
                                    Log.info(
                                        "move-halt-slide u\(idx) impassable new-tile=(\(newTX),\(newTY)) mt=\(mt) — holding pos, keeping targetMove=\(String(format: "0x%04X", slot.targetMove)) for replan",
                                        tracer: .label("move")
                                    )
                                    host.units[idx] = slot
                                    continue
                                }
                            }
                        }
                        slot.positionX = next.x
                        slot.positionY = next.y
                        didStep = true
                    }
                }

                if didStep {
                    // Crush check. Port of OpenDUNE's
                    // `Unit_Move`'s tracked-on-foot branch
                    // (`src/unit.c:1328..1349`): a tracked or
                    // harvester mover that crosses onto a foot-unit's
                    // tile kills the foot unit (`Unit_SetAction(u,
                    // ACTION_DIE)`; we short-circuit to
                    // `applyUnitDamage` which frees the slot + drops
                    // the infantry corpse sprite). Fires only on the
                    // tick we cross into a new tile, not every subpixel
                    // step.
                    let moverInfo = Simulation.UnitInfo.lookup(slot.type)
                    let moverMT = moverInfo?.movementType ?? .foot
                    let canCrush = moverMT == .tracked || moverMT == .harvester
                    if canCrush {
                        let oldTX = Int(priorX) / 256
                        let oldTY = Int(priorY) / 256
                        let newTX = Int(slot.positionX) / 256
                        let newTY = Int(slot.positionY) / 256
                        if newTX != oldTX || newTY != oldTY {
                            let newTile = (newTX, newTY)
                            // Snapshot findArray — applyUnitDamage
                            // frees slots and mutates the array.
                            for footIdx in host.units.findArray.reversed() {
                                if footIdx == idx { continue }
                                let u = host.units.slots[footIdx]
                                guard u.isUsed else { continue }
                                guard let info = Simulation.UnitInfo.lookup(u.type),
                                      info.movementType == .foot else { continue }
                                let utx = Int(u.positionX) / 256
                                let uty = Int(u.positionY) / 256
                                if utx == newTile.0, uty == newTile.1 {
                                    Log.info(
                                        "crush u\(idx) (type \(slot.type) \(moverMT)) squashed u\(footIdx) (type \(u.type) foot) at tile=(\(newTX),\(newTY))",
                                        tracer: .label("crush")
                                    )
                                    _ = Simulation.Explosions.applyUnitDamage(
                                        unitIndex: footIdx,
                                        damage: u.hitpoints,
                                        host: host
                                    )
                                }
                            }
                        }
                    }
                    // Overshoot detection: if the post-move distance
                    // to goal is >= pre-move distance, we stepped past
                    // (or at least not closer) and should snap.
                    //
                    // Wingers are excluded — their script routinely
                    // sets `currentDestination` to a fly-through
                    // point and `orientation` to something unrelated
                    // (e.g. carryall circling a landing pad, type=0
                    // with actionID=stop). For those, post-move
                    // distance-to-goal can legitimately grow every
                    // tick without "overshoot" meaning anything, and
                    // snapping would teleport the unit onto its
                    // destination. OpenDUNE's `Unit_Move`
                    // (`src/unit.c:1451`) only snaps to
                    // `currentDestination` when `ui->flags.isGroundUnit`
                    // is true; wingers fall through to the plain
                    // `unit->o.position = newPosition` at line 1512.
                    // Our position-drift was tick-parity SAVE007
                    // `unit[0]` (CARRYALL) — see
                    // `ParityHarnessTests.saveSevenParityTickZero`.
                    let after = Pos32(x: slot.positionX, y: slot.positionY)
                    let distAfter = Int32(Pos32.distance(after, goal))
                    // Bullets / missiles (movementType=.winger but
                    // isProjectileType=true) still snap-and-detonate
                    // on arrival; genuine wingers (carryall,
                    // ornithopter, frigate) don't.
                    let mt = Simulation.UnitInfo.lookup(slot.type)?.movementType
                    let isFlier = mt == .winger && !Self.isProjectileType(slot.type)
                    if !isFlier,
                       distAfter >= distBefore || distAfter <= arrivalThreshold {
                        slot.positionX = goal.x
                        slot.positionY = goal.y
                        Log.debug(
                            "move-snap u\(idx) overshoot or in-threshold — pos→(\(goal.x),\(goal.y)) distB=\(distBefore) distA=\(distAfter)",
                            tracer: .label("move")
                        )
                        // When we snap to the current route step's
                        // destination AND more route steps remain, pop
                        // the step inline so the next tick can pick up
                        // the NEXT leg without wasting a cycle on
                        // route-bookkeeping.
                        //
                        // Before this: per 16 ticks a unit spent one
                        // tick with Δ=32 (step + overshoot-snap) and
                        // the next tick with Δ=0 (arrival branch pops
                        // route but fires no step). Visible stutter at
                        // every tile boundary — the "jumps" flagged in
                        // headless screenshots for the trike driving
                        // east across mission 1.
                        if goalSource == "route", slot.route[0] != 0xFF {
                            for i in 0..<13 { slot.route[i] = slot.route[i + 1] }
                            slot.route[13] = 0xFF
                            slot.currentDestinationX = 0
                            slot.currentDestinationY = 0
                            if slot.route[0] == 0xFF {
                                slot.targetMove = 0
                            }
                            Log.debug(
                                "move-snap-pop u\(idx) inline route-pop after overshoot-snap, route[0]=\(slot.route[0])",
                                tracer: .label("move")
                            )
                        } else if goalSource != "route" {
                            // Fallback-slide arrival.
                            slot.targetMove = 0
                            slot.currentDestinationX = 0
                            slot.currentDestinationY = 0
                        }
                        host.units[idx] = slot
                        continue
                    }
                    Log.verbose(
                        "move-tick u\(idx) (t=\(slot.type) a=\(slot.actionID)) pos=(\(priorX),\(priorY))→(\(slot.positionX),\(slot.positionY)) o=\(priorOrient)→\(slot.orientationCurrent) goal=(\(goal.x),\(goal.y)) via=\(goalSource) speedPT=\(slot.speedPerTick) rem=\(slot.speedRemainder) dist=\(distBefore)→\(distAfter)",
                        tracer: .label("move")
                    )
                    // `move-track`: compact per-tick position stream so
                    // a playtester can eyeball jagged / non-continuous
                    // movement without decoding the full `move-tick`
                    // line. Emitted only while the unit actually moved
                    // this tick.
                    if !Self.isProjectileType(slot.type) {
                        let tx = Int(slot.positionX) / 256
                        let ty = Int(slot.positionY) / 256
                        Log.debug(
                            "move-track u\(idx) tile=(\(tx),\(ty)) pos=(\(slot.positionX),\(slot.positionY)) o=\(slot.orientationCurrent) dir=\(slot.route[0]) goal=(\(Int(goal.x)/256),\(Int(goal.y)/256))@(\(goal.x),\(goal.y)) via=\(goalSource)",
                            tracer: .label("move-track")
                        )
                    }
                }
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
                    budget: unitOpcodeBudget
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
                    budget: structureOpcodeBudget
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
                    budget: teamOpcodeBudget
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
