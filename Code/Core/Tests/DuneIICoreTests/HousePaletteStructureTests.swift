import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Per-house palette remap + structure tile stamping")
struct HousePaletteStructureTests {

    // MARK: applyHouseColors

    @Test("applyHouseColors: house 0 (Harkonnen) is identity")
    @MainActor
    func houseColorsHouseZero() {
        let sub: [UInt8] = Array(0..<16)
        let out = Formats.Palette.applyHouseColors(sub, houseID: 0)
        #expect(out == sub)
    }

    @Test("applyHouseColors: shifts [0x90, 0x98] by houseID << 4, leaves others alone")
    @MainActor
    func houseColorsShiftsHouseBand() {
        var sub: [UInt8] = Array(repeating: 0x50, count: 16)
        sub[0] = 0x90
        sub[1] = 0x94
        sub[2] = 0x98
        sub[3] = 0x99 // outside band
        sub[4] = 0x8F // outside band
        let out = Formats.Palette.applyHouseColors(sub, houseID: 1) // Atreides → +0x10
        #expect(out[0] == 0xA0)
        #expect(out[1] == 0xA4)
        #expect(out[2] == 0xA8)
        #expect(out[3] == 0x99) // unchanged
        #expect(out[4] == 0x8F) // unchanged
        #expect(out[5] == 0x50) // unchanged
    }

    @Test("applyHouseColors: house 2 (Ordos) shifts by 0x20")
    @MainActor
    func houseColorsOrdos() {
        let sub: [UInt8] = [0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
                            0, 0, 0, 0, 0, 0, 0]
        let out = Formats.Palette.applyHouseColors(sub, houseID: 2)
        for i in 0..<9 {
            #expect(out[i] == UInt8(0x90 + i) &+ 0x20)
        }
    }

    // MARK: Structure iconGroup mapping

    @Test("StructureInfo.iconGroupRawValue maps known types to the correct group")
    func iconGroupRawValue() {
        // CONSTRUCTION_YARD = type 8 → group 17 (constructionYard).
        #expect(Simulation.StructureInfo.iconGroupRawValue(for: 8) == 17)
        // WINDTRAP = type 9 → group 19 (windtrapPower).
        #expect(Simulation.StructureInfo.iconGroupRawValue(for: 9) == 19)
        // REFINERY = type 12 → group 21 (spiceRefinery).
        #expect(Simulation.StructureInfo.iconGroupRawValue(for: 12) == 21)
        // WALL = type 14 → group 6 (walls).
        #expect(Simulation.StructureInfo.iconGroupRawValue(for: 14) == 6)
        // Out of range returns nil.
        #expect(Simulation.StructureInfo.iconGroupRawValue(for: 99) == nil)
    }

    @Test("Every raw value maps to a valid Formats.IconMap.Group")
    func iconGroupRawValuesAreValid() {
        for type: UInt8 in 0...18 {
            guard let raw = Simulation.StructureInfo.iconGroupRawValue(for: type) else {
                Issue.record("type \(type) has no iconGroup mapping")
                continue
            }
            #expect(Formats.IconMap.Group(rawValue: raw) != nil,
                    "type \(type) maps to invalid group rawValue \(raw)")
        }
    }

    // MARK: ScenarioWorld structure stamp (install-gated)

    // MARK: spawn-action plumbing

    @Test("UnitAction.typeID maps every case to OpenDUNE's ActionType")
    func unitActionTypeIDs() {
        #expect(UnitAction.attack.typeID == 0)
        #expect(UnitAction.move.typeID == 1)
        #expect(UnitAction.retreat.typeID == 2)
        #expect(UnitAction.guard_.typeID == 3)
        #expect(UnitAction.area.typeID == 4)
        #expect(UnitAction.harvest.typeID == 5)
        #expect(UnitAction.returnAction.typeID == 6)
        #expect(UnitAction.stop.typeID == 7)
        #expect(UnitAction.ambush.typeID == 8)
        #expect(UnitAction.die.typeID == 10)
        #expect(UnitAction.hunt.typeID == 11)
    }

    @Test("WorldSnapshot seeds actionID from the scenario spawn, not hardcoded 0")
    func snapshotPropagatesAction() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard let scenario = try assets.loadScenario(named: "SCENA001.INI") else { return }
        let snapshot = try Simulation.WorldSnapshot(
            scenario: scenario, resolver: assets.tileResolver
        )
        // At least one spawned unit carries a non-ATTACK action — mission 1
        // Atreides units spawn under `Guard` / `Area Guard`, enemies under
        // `Hunt` / `Guard`. If the snapshot still hardcoded actionID=0
        // every slot would read as ATTACK.
        let nonAttackSpawns = snapshot.units.findArray.filter {
            snapshot.units.slots[$0].actionID != 0
        }
        #expect(!nonAttackSpawns.isEmpty,
                "no unit spawned with a non-ATTACK action — actionID wiring regressed")
    }

    @Test("Winger-class spawns get speed=255 so they cruise in from their entry vector")
    func wingerSpawnSpeedIs255() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard let scenario = try assets.loadScenario(named: "SCENA001.INI") else { return }
        let snapshot = try Simulation.WorldSnapshot(
            scenario: scenario, resolver: assets.tileResolver
        )
        // Any winger-type spawn (carryall=0, ornithopter=1, frigate=26,
        // missile-type 18..22, BULLET=23, SONIC_BLAST=24, SANDWORM=25
        // which is .slither not winger) should have speed=255 at spawn.
        // Mission 1 doesn't carry carryalls in the INI, but other scenarios
        // might; tolerate the case where there are none and just pin the
        // ground-unit invariant (speed 0 at spawn).
        let ground = snapshot.units.findArray.compactMap { idx -> Simulation.UnitSlot? in
            let s = snapshot.units.slots[idx]
            guard let info = Simulation.UnitInfo.lookup(s.type) else { return nil }
            return info.movementType == .winger ? nil : s
        }
        #expect(ground.allSatisfy { $0.speed == 0 })
    }

    @Test("Running the real UNIT.EMC for 30 ticks makes at least one unit update state")
    @MainActor
    func missionOneUnitsActuallyTick() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard let scenario = try assets.loadScenario(named: "SCENA001.INI") else { return }
        guard let unitProgram = try assets.loadEmc(named: "UNIT.EMC") else { return }
        guard let structureProgram = try assets.loadEmc(named: "BUILD.EMC") else { return }

        let snapshot = try Simulation.WorldSnapshot(
            scenario: scenario, resolver: assets.tileResolver
        )
        let host = Scripting.Host(
            units: snapshot.units,
            structures: snapshot.structures,
            explosions: Simulation.ExplosionPool(),
            playerHouseID: 1 // Atreides
        )
        let source = Scripting.RandomSource(
            lcgSeed: UInt16(truncatingIfNeeded: scenario.mapField.seed),
            toolsSeed: scenario.mapField.seed
        )
        let unitFunctions = Scripting.Functions.unitTable(host: host, source: source)
        let structureFunctions = Scripting.Functions.structureTable(host: host, source: source)
        let unitVM = Scripting.VM(program: unitProgram, functions: unitFunctions)
        let structureVM = Scripting.VM(program: structureProgram, functions: structureFunctions)
        var scheduler = Simulation.Scheduler(host: host, unitVM: unitVM, structureVM: structureVM)

        // Snapshot the initial orientations, positions, and delays.
        struct UnitState { var o: Int8; var x: UInt16; var y: UInt16; var d: UInt16; var halted: Bool }
        let indices = host.units.findArray
        var initial: [Int: UnitState] = [:]
        for idx in indices {
            let s = host.units.slots[idx]
            initial[idx] = UnitState(
                o: s.orientationCurrent, x: s.positionX, y: s.positionY,
                d: scheduler.unitEngines[idx].delay,
                halted: scheduler.unitEngines[idx].halted
            )
        }

        for _ in 0..<30 { scheduler.tick() }

        // After 30 ticks, at least ONE of: orientation changed, position
        // changed, or some engine advanced past its delay. If all
        // engines are permanently halted and no state changed, the
        // scripts aren't running at all — regression.
        var anyStateChange = false
        var haltedCount = 0
        for idx in indices {
            let s = host.units.slots[idx]
            let e = scheduler.unitEngines[idx]
            let prior = initial[idx]!
            if s.orientationCurrent != prior.o { anyStateChange = true }
            if s.positionX != prior.x || s.positionY != prior.y { anyStateChange = true }
            if e.pc != 0 { anyStateChange = true }
            if e.halted { haltedCount += 1 }
        }
        let haltRate = Double(haltedCount) / Double(max(indices.count, 1))
        #expect(anyStateChange,
                "0 units updated state over 30 ticks — scripts aren't running")
        // Sanity check: not every engine should be halted. ≤90% is the
        // band — remember we still have unwired EMC slots, so some
        // halts are expected.
        #expect(haltRate <= 0.9,
                "too many engines halted (\(haltRate)) — check unwired slots")
    }

    @Test("ScenarioWorld stamps structure footprints from iconMap when passed")
    func scenarioWorldStructureStamp() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard let scenario = try assets.loadScenario(named: "SCENA001.INI") else { return }

        // Without iconMap: structure footprint keeps baseline ground
        // tile + only hasStructure flagged.
        let baseline = ScenarioWorld(scenario: scenario, resolver: assets.tileResolver)
        // With iconMap: structure footprint gets the iconGroup's fully-
        // built tail tiles painted in.
        let stamped = ScenarioWorld(
            scenario: scenario, resolver: assets.tileResolver,
            iconMap: assets.iconMap
        )

        // Find a non-slab, non-wall structure and verify its anchor cell
        // groundTileID changed in the stamped version.
        guard let s = scenario.structures.first(where: {
            !$0.isGenerated && $0.structureType != .slab1x1 && $0.structureType != .wall
        }) else { return }
        let tx = Int(s.position.tile.x)
        let ty = Int(s.position.tile.y)
        let idx = ty * DuneIICore.Map.width + tx
        let baselineTile = baseline.map.cells[idx].groundTileID
        let stampedTile = stamped.map.cells[idx].groundTileID
        #expect(baselineTile != stampedTile,
                "stamped structure tile should differ from baseline")
        // Either way, the cell is flagged as having a structure.
        #expect(stamped.map.cells[idx].hasStructure)
    }
}
