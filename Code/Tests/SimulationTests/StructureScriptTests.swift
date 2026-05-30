import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Real-data integration for the structure script subsystem: bridge the committed `BUILD.EMC` into a
/// `ScriptInfo`, place a structure, and drive `Simulation.tick()` so `GameLoop_Structure` loads + runs its
/// EMC script. Covers (a) a healthy structure idling without being removed, and (b) the death path —
/// damaging a structure to 0 HP → its reloaded death script runs Explode→Delay→Destroy → `Structure_Remove`
/// frees the slot, drops it from the find array, and clears the tile occupancy. Plus focused decision-trace
/// coverage of the state natives. See `Documentation/Algorithms/StructureScript.md`.
@Suite("Structure scripts (BUILD.EMC under the VM)")
struct StructureScriptTests {
    private func emc(_ relative: String) -> ScriptInfo? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/SimulationTests → repo root
        guard let data = try? Data(contentsOf: repo.appendingPathComponent(relative)),
              let program = try? Emc.Program(data) else { return nil }
        return ScriptInfo(program)
    }

    /// A `Simulation` with both EMCs bridged and a single `windtrap` placed for `house`, HP 200, idle. The
    /// structure's 2×2 tile occupancy is stamped manually (no `iconMap` needed for the script path).
    private func setup(house: UInt8 = 0, player: UInt8 = 0) -> (Simulation, Int, [Int])? {
        guard let unit = emc("Resources/Scripts/UNIT/UNIT.emc"),
              let build = emc("Resources/Scripts/BUILD/BUILD.emc") else { return nil }

        var s = GameState(random256Seed: 0x51234)
        s.playerHouseID = player
        _ = s.houseAllocate(index: house)
        s.houses[Int(house)].unitCountMax = 100

        let slot = s.structureAllocate(index: Pool.structureIndexInvalid,
                                       type: UInt8(StructureType.windtrap.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.position = Tile32.unpack(20 * 64 + 20)
        s.structures[slot].state = .idle
        s.structures[slot].o.hitpoints = 200

        // Stamp the structure's tile occupancy (the bit of `structureUpdateMap` that doesn't need an
        // iconMap): `hasStructure` plus the 1-based pool `index`, so a fog reveal / pool query that hits the
        // building's own tiles resolves the slot rather than reading a 0 index.
        let layout = StructureLayoutInfo[StructureInfo[.windtrap].layout]
        let base = Int(s.structures[slot].o.position.packed)
        var tiles: [Int] = []
        for i in 0 ..< Int(layout.tileCount) {
            let p = base + Int(layout.tiles[i])
            s.map[p].hasStructure = true
            s.map[p].index = UInt8(truncatingIfNeeded: slot + 1)
            s.map[p].houseID = house
            tiles.append(p)
        }

        let sim = Simulation(state: s, scriptInfo: unit, structureScriptInfo: build)
        return (sim, slot, tiles)
    }

    private func structureSlots(_ s: GameState) -> [Int] {
        var s = s, find = PoolFind(), slots: [Int] = []
        while let slot = s.structureFind(&find) { slots.append(slot) }
        return slots
    }

    @Test("BUILD.EMC bridges + a healthy structure's script loads and idles without removing it")
    func healthyIdles() throws {
        guard var (sim, slot, _) = setup() else { return }   // short-circuit if the scripts are absent

        // One game tick past the first structure-script tick loads the type's script.
        for _ in 0 ..< 6 { sim.tick() }
        #expect(sim.structureScript != nil)

        // Idle for a while: a healthy windtrap is never destroyed, and the death flag stays clear.
        for _ in 0 ..< 200 { sim.tick() }
        #expect(sim.state.structures[slot].o.flags.contains(.used))
        #expect(sim.state.structures[slot].o.hitpoints == 200)
        #expect(sim.state.structures[slot].o.script.variables[0] == 0)
        #expect(structureSlots(sim.state).contains(slot))
    }

    @Test("damaging a structure to 0 HP runs the death script → Structure_Remove (slot freed, tiles cleared)")
    func deathPathRemovesStructure() throws {
        guard var (sim, slot, tiles) = setup(house: 1, player: 0) else { return }   // enemy windtrap

        // Lethal damage begins destruction: death flag set, but the slot is not yet freed (the death
        // script, driven by GameLoop_Structure, removes it).
        let destroyed = sim.state.structureDamage(slot, damage: 500, range: 0)
        #expect(destroyed)
        #expect(sim.state.structures[slot].o.script.variables[0] == 1)
        #expect(sim.state.structures[slot].o.flags.contains(.used))

        // Drive the loop: the reloaded death script runs Explode → Delay → Destroy → Structure_Remove.
        var removed = false
        for _ in 0 ..< 3000 where !removed {
            sim.tick()
            removed = !sim.state.structures[slot].o.flags.contains(.used)
        }
        #expect(removed)
        #expect(!structureSlots(sim.state).contains(slot))           // dropped from the find array
        for p in tiles { #expect(!sim.state.map[p].hasStructure) }   // tile occupancy cleared
    }

    // MARK: - Turret natives (0x08–0x0B)

    /// A minimal `GameState` (houses 0 player + 1 enemy) + a `UnitCombat` built on a stub `ScriptInfo`, for
    /// directly exercising the structure natives without the full EMC/iconMap.
    private func minimal() -> (GameState, UnitCombat) {
        var s = GameState(random256Seed: 0x777)
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 200
        _ = s.houseAllocate(index: 1); s.houses[1].unitCountMax = 200
        let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    private func placeTurret(_ s: inout GameState, _ type: StructureType, house: UInt8, at packed: UInt16) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.position = Tile32.unpack(packed)
        s.structures[slot].o.hitpoints = 200
        return slot
    }

    @discardableResult
    private func placeUnit(_ s: inout GameState, _ type: UnitType, house: UInt8, at packed: UInt16,
                           seenBy: UInt8? = 0) -> Int {
        let slot = s.unitAllocate(index: Pool.unitIndexInvalid, type: UInt8(type.rawValue), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(packed)
        s.units[slot].o.hitpoints = 200
        if let seenBy { s.units[slot].o.seenByHouses |= UInt8(1 << seenBy) }
        return slot
    }

    @Test("Script_Structure_FindTargetUnit picks the last in-range, seen, non-allied unit (1.07)")
    func findTargetUnit() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let turret = placeTurret(&s, .turret, house: 0, at: 20 * 64 + 20)

        let a = placeUnit(&s, .tank, house: 1, at: 20 * 64 + 21, seenBy: 0)   // seen enemy, in range
        let b = placeUnit(&s, .tank, house: 1, at: 20 * 64 + 22, seenBy: 0)   // seen enemy, in range, later in pool
        // 1.07 returns the LAST matching unit in pool order, not the closest → b.
        #expect(fns.findTargetUnit(slot: turret, range: 1280, in: &s) == s.indexEncode(UInt16(s.units[b].o.index), type: .unit))
        _ = a

        // Allied (same house) ignored; unseen ignored; out-of-range ignored.
        var (s2, c2) = minimal()
        let f2 = StructureScriptFunctions(combat: c2)
        let t2 = placeTurret(&s2, .turret, house: 0, at: 20 * 64 + 20)
        placeUnit(&s2, .tank, house: 0, at: 20 * 64 + 21, seenBy: 0)          // allied
        placeUnit(&s2, .tank, house: 1, at: 20 * 64 + 21, seenBy: nil)        // not seen by house 0
        placeUnit(&s2, .tank, house: 1, at: 20 * 64 + 40, seenBy: 0)          // 20 tiles away, out of range 1280 (5)
        #expect(f2.findTargetUnit(slot: t2, range: 1280, in: &s2) == 0)
    }

    @Test("Script_Structure_GetDirection: 8-orientation ×32 to a tile, or the turret facing if invalid")
    func getDirection() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let turret = placeTurret(&s, .turret, house: 0, at: 20 * 64 + 20)

        // Invalid index → current facing (rotationSpriteDiff << 5).
        s.structures[turret].rotationSpriteDiff = 3
        #expect(fns.getDirection(slot: turret, encoded: 0, in: s) == 3 << 5)

        // Valid tile → (orientation8 to that tile) << 5, a multiple of 32 matching the primitive.
        let target = UInt16(20 * 64 + 24)   // due east
        let encoded = s.indexEncode(target, type: .tile)
        let expected = UInt16(Orientation.to8(UInt8(bitPattern: Tile32.direction(from: s.structures[turret].o.position, to: Tile32.unpack(target))))) << 5
        let got = fns.getDirection(slot: turret, encoded: encoded, in: s)
        #expect(got == expected)
        #expect(got % 32 == 0)
    }

    @Test("Script_Structure_Fire spawns a bullet at the target, stamped with the structure as origin")
    func fire() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let turret = placeTurret(&s, .turret, house: 0, at: 20 * 64 + 20)
        let enemy = placeUnit(&s, .tank, house: 1, at: 20 * 64 + 23, seenBy: 0)

        s.structures[turret].o.script.variables[2] = s.indexEncode(UInt16(s.units[enemy].o.index), type: .unit)
        let delay = fns.fire(slot: turret, in: &s)
        #expect(delay > 0)   // returns the speed-adjusted fire delay

        // A gun turret fires a UNIT_BULLET (type 23), origin = the turret structure.
        var find = PoolFind(), bullet: Int?
        while bullet == nil, let u = s.unitFind(&find) {
            if s.units[u].o.type == UInt8(UnitType.bullet.rawValue) { bullet = u }
        }
        let b = try! #require(bullet)
        #expect(s.units[b].originEncoded == s.indexEncode(UInt16(s.structures[turret].o.index), type: .structure))

        // No target → no shot.
        s.structures[turret].o.script.variables[2] = 0
        #expect(fns.fire(slot: turret, in: &s) == 0)
    }

    @Test("a placed turret acquires + fires at a seen enemy over GameLoop_Structure ticks")
    func turretFiresAtEnemy() throws {
        guard let unit = emc("Resources/Scripts/UNIT/UNIT.emc"),
              let build = emc("Resources/Scripts/BUILD/BUILD.emc") else { return }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        guard let iconMap = try? IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP"))) else { return }

        var s = GameState(random256Seed: 0x2468)
        s.playerHouseID = 0
        s.iconMap = iconMap
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 200
        _ = s.houseAllocate(index: 1); s.houses[1].unitCountMax = 200

        let turret = placeTurret(&s, .turret, house: 0, at: 20 * 64 + 20)
        s.structureUpdateMap(turret)                                   // stamp groundTileID (rotation 0)
        placeUnit(&s, .tank, house: 1, at: 20 * 64 + 23, seenBy: 0)    // a seen enemy 3 tiles east

        var sim = Simulation(state: s, scriptInfo: unit, structureScriptInfo: build)

        func bulletExists() -> Bool {
            var find = PoolFind()
            while let u = sim.state.unitFind(&find) {
                let t = sim.state.units[u].o.type
                if t == UInt8(UnitType.bullet.rawValue) || t == UInt8(UnitType.missileTurret.rawValue) { return true }
            }
            return false
        }

        var fired = false
        for _ in 0 ..< 800 where !fired {
            sim.tick()
            fired = bulletExists()
        }
        #expect(fired)   // the turret found the enemy, rotated to aim, and fired
    }

    // MARK: - RefineSpice (0x15)

    @Test("Script_Structure_RefineSpice converts a linked harvester's spice into the owner's credits")
    func refineSpice() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let ref = placeTurret(&s, .refinery, house: 0, at: 20 * 64 + 20)
        s.structures[ref].o.hitpoints = StructureInfo[.refinery].o.hitpoints   // full HP → step 3
        s.structures[ref].state = .busy

        // No linked unit → SetState(IDLE), no credits.
        s.structures[ref].o.linkedID = 0xFF
        #expect(fns.refineSpice(slot: ref, in: &s) == 0)
        #expect(s.structures[ref].state == .idle)
        #expect(s.houses[0].credits == 0)

        // Link a player harvester carrying 10 spice.
        let harv = placeUnit(&s, .harvester, house: 0, at: 20 * 64 + 25, seenBy: nil)
        s.units[harv].amount = 10
        s.units[harv].o.flags.insert(.inTransport)
        s.structures[ref].o.linkedID = UInt8(harv)

        // One refine: player credits = 7 × step(3) = 21; amount 10→7; throttle delay 6; still refining.
        #expect(fns.refineSpice(slot: ref, in: &s) == 1)
        #expect(s.houses[0].credits == 21)
        #expect(s.units[harv].amount == 7)
        #expect(s.structures[ref].o.script.delay == 6)
        #expect(s.units[harv].o.flags.contains(.inTransport))   // not empty yet
    }

    @Test("RefineSpice clears inTransport when the harvester is emptied")
    func refineEmpties() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let ref = placeTurret(&s, .refinery, house: 0, at: 20 * 64 + 20)
        s.structures[ref].o.hitpoints = StructureInfo[.refinery].o.hitpoints
        let harv = placeUnit(&s, .harvester, house: 0, at: 20 * 64 + 25, seenBy: nil)
        s.units[harv].amount = 2          // < step(3) → clamps to 2
        s.units[harv].o.flags.insert(.inTransport)
        s.structures[ref].o.linkedID = UInt8(harv)

        #expect(fns.refineSpice(slot: ref, in: &s) == 1)
        #expect(s.houses[0].credits == 14)   // 7 × 2
        #expect(s.units[harv].amount == 0)
        #expect(!s.units[harv].o.flags.contains(.inTransport))   // emptied
    }

    @Test("RefineSpice gives an enemy refinery a small ±RNG credit bonus")
    func refineEnemyVariance() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let ref = placeTurret(&s, .refinery, house: 1, at: 20 * 64 + 20)   // enemy house
        s.structures[ref].o.hitpoints = StructureInfo[.refinery].o.hitpoints
        let harv = placeUnit(&s, .harvester, house: 1, at: 20 * 64 + 25, seenBy: nil)
        s.units[harv].amount = 10
        s.structures[ref].o.linkedID = UInt8(harv)

        #expect(fns.refineSpice(slot: ref, in: &s) == 1)
        // creditsStep ∈ {6,7,8,9} × step(3) = {18,21,24,27}.
        #expect((18 ... 27).contains(s.houses[1].credits))
    }

    // MARK: - Deploy cluster (Unit_SetPosition / Structure_FindFreePosition / unit-unload 0x07)

    @Test("Unit_SetPosition places an off-map unit on a free tile, fails on an occupied one")
    func unitSetPosition() {
        var (s, combat) = minimal()
        let slot = s.unitAllocate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.tank.rawValue), houseID: 1)!
        s.units[slot].o.flags.insert(.isNotOnMap)

        // Free tile → placed (centred, on-map), and a second unit can't take the same tile.
        #expect(combat.unitSetPosition(slot: slot, position: Tile32.unpack(20 * 64 + 20), in: &s))
        #expect(!s.units[slot].o.flags.contains(.isNotOnMap))
        #expect(s.units[slot].o.position.packed == 20 * 64 + 20)
        #expect(s.map[20 * 64 + 20].hasUnit)

        let other = s.unitAllocate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.tank.rawValue), houseID: 1)!
        s.units[other].o.flags.insert(.isNotOnMap)
        #expect(!combat.unitSetPosition(slot: other, position: Tile32.unpack(20 * 64 + 20), in: &s))   // occupied
        #expect(s.units[other].o.flags.contains(.isNotOnMap))
    }

    @Test("Structure_FindFreePosition returns a free adjacent tile, or 0 when the ring is full")
    func findFreePosition() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let st = placeTurret(&s, .turret, house: 0, at: 20 * 64 + 20)

        let pos = fns.findFreePosition(slot: st, checkForSpice: false, in: &s)
        #expect(pos != 0)
        // The returned tile is in the structure's surrounding ring and is unoccupied passable ground.
        let ringInts: [Int] = [20 * 64 + 19, 20 * 64 + 21, 19 * 64 + 20, 21 * 64 + 20,
                               19 * 64 + 19, 19 * 64 + 21, 21 * 64 + 19, 21 * 64 + 21]
        let ring = Set(ringInts.map { UInt16($0) })
        #expect(ring.contains(pos))

        // Fill the whole ring → no free position.
        for p in ring { s.map[Int(p)].hasStructure = true }
        #expect(fns.findFreePosition(slot: st, checkForSpice: false, in: &s) == 0)
    }

    @Test("unit-unload deploys a structure's linked unit to a free tile and unlinks it")
    func unloadLinkedUnit() {
        var (s, combat) = minimal()
        let fns = StructureScriptFunctions(combat: combat)
        let st = placeTurret(&s, .refinery, house: 1, at: 20 * 64 + 20)
        s.structures[st].state = .busy

        // No link → 0.
        s.structures[st].o.linkedID = 0xFF
        #expect(fns.unloadLinkedUnit(slot: st, in: &s) == 0)

        // Link a ground unit (inside the structure, off-map) and unload it.
        let unit = s.unitAllocate(index: Pool.unitIndexInvalid, type: UInt8(UnitType.tank.rawValue), houseID: 1)!
        s.units[unit].o.flags.insert(.isNotOnMap)
        s.units[unit].o.linkedID = 0xFF                 // end of the link chain
        s.structures[st].o.linkedID = UInt8(unit)

        #expect(fns.unloadLinkedUnit(slot: st, in: &s) == 1)
        #expect(!s.units[unit].o.flags.contains(.isNotOnMap))      // deployed onto the map
        #expect(s.map[Int(s.units[unit].o.position.packed)].hasUnit)
        #expect(s.units[unit].o.linkedID == 0xFF)
        #expect(s.structures[st].o.linkedID == 0xFF)               // structure's chain now empty
        #expect(s.structures[st].state == .idle)                   // → IDLE once unlinked
    }

    @Test("Script_Structure_SetState resolves DETECT, GetState reports it")
    func setStateDetect() throws {
        guard var (sim, slot, _) = setup() else { return }
        let combat = sim.unitScript!.combat
        let fns = StructureScriptFunctions(combat: combat)

        // DETECT with no linked unit → IDLE.
        sim.state.structures[slot].o.linkedID = 0xFF
        _ = fns.setState(slot: slot, state: StructureState.detect.rawValue, in: &sim.state)
        #expect(sim.state.structures[slot].state == .idle)
        #expect(fns.getState(slot: slot, in: sim.state) == UInt16(bitPattern: StructureState.idle.rawValue))

        // DETECT with a linked unit + a running countdown → BUSY.
        sim.state.structures[slot].o.linkedID = 3
        sim.state.structures[slot].countDown = 50
        _ = fns.setState(slot: slot, state: StructureState.detect.rawValue, in: &sim.state)
        #expect(sim.state.structures[slot].state == .busy)

        // DETECT with a linked unit + countdown elapsed → READY.
        sim.state.structures[slot].countDown = 0
        _ = fns.setState(slot: slot, state: StructureState.detect.rawValue, in: &sim.state)
        #expect(sim.state.structures[slot].state == .ready)
    }
}
