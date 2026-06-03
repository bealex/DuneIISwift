import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Scenario-level integration tests for in-game interactions driven through the live `Simulation` with the
/// real `UNIT.EMC` / `BUILD.EMC` scripts: a dying foot unit leaving a **corpse** that lingers then clears,
/// a destroyed building spawning **soldiers** from its debris, the building's **rubble** animation, and an
/// **explosion** running through its sprite sequence and ending. The deterministic per-native pieces live in
/// `ExplosionTests`/`AnimationTests`/`StructureScriptTests`; this drives them end-to-end.
@Suite("In-game interactions")
struct InteractionTests {
    private struct Assets { let unit: ScriptInfo; let build: ScriptInfo; let iconMap: IconMap }

    private func load() -> Assets? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/SimulationTests → repo
        guard
            let unitData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let buildData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
            let iconData = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
            let unit = try? Emc.Program(unitData),
            let build = try? Emc.Program(buildData),
            let iconMap = try? IconMap(iconData)
        else { return nil }
        return Assets(unit: ScriptInfo(unit), build: ScriptInfo(build), iconMap: iconMap)
    }

    // MARK: - Troop death → corpse lingers, then clears

    @Test("a killed foot soldier leaves a corpse that lingers, then clears", .timeLimit(.minutes(1)))
    func soldierLeavesCorpse() throws {
        guard let a = load() else { return }
        var state = GameState(random256Seed: 0x1234)
        state.playerHouseID = 0
        _ = state.houseAllocate(index: 0); state.houses[0].unitCountMax = 100
        state.tileIDs = TileIDs(iconMap: a.iconMap) ?? TileIDs()
        state.iconMap = a.iconMap
        state.mapScale = 0

        let deathTile = Int(Tile32.packXY(x: 20, y: 20))
        state.map[deathTile].isUnveiled = true  // so the corpse overlay is set
        let soldier = state.unitAllocate(index: 0, type: UInt8(UnitType.soldier.rawValue), houseID: 0)!
        state.units[soldier].o.position = Tile32.unpack(UInt16(deathTile))
        state.units[soldier].o.hitpoints = UnitInfo[.soldier].o.hitpoints
        UnitActions().setAction(
            slot: soldier,
            action: UInt8(ActionType.guard_.rawValue),
            scriptInfo: a.unit,
            in: &state
        )
        state.unitUpdateMap(1, soldier)

        var sim = Simulation(state: state, scriptInfo: a.unit, structureScriptInfo: a.build, tickAnimations: true)
        // Kill it → action DIE; the DIE script runs Stop → StartAnimation (corpse) → Die (removes the body).
        let died = sim.unitScript!.combat.damage(slot: soldier, damage: 9999, range: 0, in: &sim.state)
        #expect(died)

        for _ in 0 ..< 50 { sim.tick() }  // the DIE script takes ~30 ticks
        #expect(!sim.state.units[soldier].o.flags.contains(.used), "the body should be removed by Unit_Die")
        #expect(sim.state.map[deathTile].hasAnimation, "a corpse animation should linger on the tile")
        #expect(sim.state.map[deathTile].overlayTileID != 0, "the corpse sprite should be on the overlay tile")

        // It persists for a good while (two PAUSE 600s), not a single tick.
        for _ in 0 ..< 200 { sim.tick() }
        #expect(sim.state.map[deathTile].hasAnimation, "the corpse should still be there after 200 ticks")

        // …and is eventually cleared (the overlay is removed on STOP).
        var cleared = false
        for _ in 0 ..< 2000 { sim.tick(); if !sim.state.map[deathTile].hasAnimation { cleared = true; break } }
        #expect(cleared, "the corpse should eventually be cleared")
        #expect(sim.state.map[deathTile].overlayTileID == 0)
    }

    // MARK: - Building destruction → soldier spawn + rubble

    @Test("destroying a building spawns soldiers from the debris and leaves rubble", .timeLimit(.minutes(1)))
    func buildingDestructionSpawnsSoldiers() throws {
        guard let a = load() else { return }
        var state = GameState(random256Seed: 0x51234)
        state.playerHouseID = 0
        _ = state.houseAllocate(index: 1); state.houses[1].unitCountMax = 100  // an enemy-owned palace
        state.tileIDs = TileIDs(iconMap: a.iconMap) ?? TileIDs()
        state.iconMap = a.iconMap
        state.mapScale = 0

        let pal = state.structureAllocate(
            index: Pool.structureIndexInvalid,
            type: UInt8(StructureType.palace.rawValue)
        )!
        state.structures[pal].o.houseID = 1
        state.structures[pal].state = .idle
        state.structures[pal].o.hitpoints = 100
        state.structures[pal].o.position = Tile32.unpack(Tile32.packXY(x: 20, y: 20))  // a 3×3 corner
        let layout = StructureLayoutInfo[StructureInfo[.palace].layout]
        let base = Int(state.structures[pal].o.position.packed)
        var tiles: [Int] = []
        for i in 0 ..< Int(layout.tileCount) {
            let p = base + Int(layout.tiles[i])
            state.map[p].hasStructure = true
            state.map[p].index = UInt8(truncatingIfNeeded: pal + 1)
            state.map[p].houseID = 1
            state.map[p].isUnveiled = true
            tiles.append(p)
        }

        var sim = Simulation(state: state, scriptInfo: a.unit, structureScriptInfo: a.build, tickAnimations: true)
        let destroyed = sim.state.structureDamage(pal, damage: 500, range: 0)
        #expect(destroyed)

        // Drive the death script: Explode → Delay → Destroy (op 0x17 spawns soldiers + Structure_Remove).
        var removed = false
        for _ in 0 ..< 3000 where !removed {
            sim.tick()
            removed = !sim.state.structures[pal].o.flags.contains(.used)
        }
        #expect(removed, "the building should be removed by its death script")

        let soldiers = sim.state.units.indices.filter {
            sim.state.units[$0].o.flags.contains(.used)
                && sim.state.units[$0].o.type == UInt8(UnitType.soldier.rawValue)
        }
        #expect(!soldiers.isEmpty, "the debris should spawn soldiers")
        // They stand on (or next to) the building's footprint.
        #expect(soldiers.allSatisfy { sim.state.units[$0].o.houseID == 1 })

        // The destruction kicked off a rubble animation on the footprint.
        #expect(tiles.contains { sim.state.map[$0].hasAnimation }, "a rubble animation should be running")
    }

    // MARK: - Explosion lifecycle

    @Test("an impact explosion advances through its sprite frames and then ends")
    func impactExplosionRunsAndEnds() {
        var sim = Simulation(random256Seed: 7, tickExplosions: true)
        sim.state.explosionStart(
            type: ExplosionType.impactMedium.rawValue,
            position: Tile32(x: 20 * 256 + 0x80, y: 20 * 256 + 0x80)
        )
        #expect(sim.state.explosions.contains { $0.active }, "an explosion should be running")

        var sprites = Set<UInt16>()
        var ended = false
        for _ in 0 ..< 300 {
            sim.tick()
            if let e = sim.state.explosions.first(where: { $0.active }) { sprites.insert(e.spriteID) }
            if !sim.state.explosions.contains(where: { $0.active }) { ended = true; break }
        }
        #expect(sprites.count > 1, "the explosion should cycle through multiple sprite frames")
        #expect(ended, "the explosion should finish and free its slot")
    }
}
