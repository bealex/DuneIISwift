import Foundation
import Testing
@testable import DuneIICore

@Suite("Simulation.WorldSnapshot")
struct SimulationWorldSnapshotTests {
    // MARK: Synthetic composition

    @Test("single-house / single-unit / single-structure save composes into populated pools")
    func syntheticSingleOfEach() throws {
        let game = makeSingleEntityGame(
            houseIndex: 2,
            unitIndex: 7, unitType: 3, unitHouse: 2,
            structIndex: 5, structType: 9, structHouse: 2
        )
        let baseline = makeBaseline(groundTileID: 42)
        let snap = try Simulation.WorldSnapshot(loading: game, baseline: baseline)

        // Houses: exactly one allocated at index 2.
        #expect(snap.houses.findArray == [2])
        #expect(snap.houses[2].isUsed)

        // Units: exactly one allocated at index 7.
        #expect(snap.units.findArray == [7])
        #expect(snap.units[7].isUsed)
        #expect(snap.units[7].isAllocated)
        #expect(snap.units[7].type == 3)
        #expect(snap.units[7].houseID == 2)

        // Structures: exactly one allocated at index 5.
        #expect(snap.structures.findArray == [5])
        #expect(snap.structures[5].isUsed)
        #expect(snap.structures[5].type == 9)
        #expect(snap.structures[5].houseID == 2)

        // Tiles: 4096, baseline ground, flags clear.
        #expect(snap.tiles.count == 4096)
        #expect(snap.tiles[0].groundTileID == 42)
        #expect(!snap.tiles[0].isUnveiled)
        #expect(snap.tiles[0].objectRef == 0)
    }

    @Test("sparse tile overrides replace baseline at specific cells, leave others alone")
    func tileOverrideLayering() throws {
        var game = makeSingleEntityGame(
            houseIndex: 0,
            unitIndex: 0, unitType: 0, unitHouse: 0,
            structIndex: 0, structType: 0, structHouse: 0
        )
        // Inject two sparse overrides: cell 10 (unveiled, hasUnit, objectRef=1)
        // and cell 4095 (hasStructure, houseID=3).
        let entries: [Formats.Save.TileMap.Entry] = [
            .init(cellIndex: 10, tile: Formats.Save.TileMap.Tile(
                groundTileID: 500, overlayTileID: 7, houseID: 0,
                isUnveiled: true, hasUnit: true, hasStructure: false,
                hasAnimation: false, hasExplosion: false, tileIndex: 1
            )),
            .init(cellIndex: 4095, tile: Formats.Save.TileMap.Tile(
                groundTileID: 123, overlayTileID: 0, houseID: 3,
                isUnveiled: false, hasUnit: false, hasStructure: true,
                hasAnimation: false, hasExplosion: false, tileIndex: 12
            ))
        ]
        game = replacingTileMap(game, with: Formats.Save.TileMap(entries: entries))

        let baseline = makeBaseline(groundTileID: 99)
        let snap = try Simulation.WorldSnapshot(loading: game, baseline: baseline)

        // Cell 10 is overridden.
        #expect(snap.tiles[10].groundTileID == 500)
        #expect(snap.tiles[10].overlayTileID == 7)
        #expect(snap.tiles[10].isUnveiled)
        #expect(snap.tiles[10].hasUnit)
        #expect(snap.tiles[10].objectRef == 1)

        // Cell 4095 is overridden.
        #expect(snap.tiles[4095].groundTileID == 123)
        #expect(snap.tiles[4095].houseID == 3)
        #expect(snap.tiles[4095].hasStructure)
        #expect(snap.tiles[4095].objectRef == 12)

        // Any other cell carries the baseline ground.
        #expect(snap.tiles[0].groundTileID == 99)
        #expect(snap.tiles[11].groundTileID == 99)
        #expect(snap.tiles[4094].groundTileID == 99)
    }

    // MARK: Failure modes

    @Test("duplicate house index is rejected")
    func duplicateHouse() throws {
        var game = makeSingleEntityGame(
            houseIndex: 0,
            unitIndex: 0, unitType: 0, unitHouse: 0,
            structIndex: 0, structType: 0, structHouse: 0
        )
        // Inject a second house slot at the same index.
        let dup = Formats.Save.Player.HouseSlot(
            index: 0, harvestersIncoming: 0,
            flags: Formats.Save.Player.HouseFlags(rawWord: 0x01),
            unitCount: 0, unitCountMax: 0, unitCountEnemy: 0, unitCountAllied: 0,
            structuresBuilt: 0,
            credits: 0, creditsStorage: 0, powerProduction: 0, powerUsage: 0,
            windtrapCount: 0, creditsQuota: 0,
            palacePositionX: 0, palacePositionY: 0,
            timerUnitAttack: 0, timerSandwormAttack: 0, timerStructureAttack: 0,
            starportTimeLeft: 0, starportLinkedID: 0xFFFF,
            aiStructureRebuild: [UInt16](repeating: 0, count: 10)
        )
        game = replacingPlayer(game, with: Formats.Save.Player(slots: game.houses.slots + [dup]))

        let baseline = makeBaseline(groundTileID: 0)
        #expect(throws: Simulation.WorldSnapshot.LoadError.duplicateHouseIndex(0)) {
            _ = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        }
    }

    @Test("unit index >= 102 is rejected")
    func unitIndexOutOfRange() throws {
        var game = makeSingleEntityGame(
            houseIndex: 0, unitIndex: 0, unitType: 0, unitHouse: 0,
            structIndex: 0, structType: 0, structHouse: 0
        )
        let badUnit = makeUnitRecord(index: 200, type: 0, houseID: 0)
        game = replacingUnits(game, with: Formats.Save.Units(slots: [badUnit]))
        let baseline = makeBaseline(groundTileID: 0)
        #expect(throws: Simulation.WorldSnapshot.LoadError.unitIndexOutOfRange(200)) {
            _ = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        }
    }

    @Test("structure index >= 82 is rejected")
    func structureIndexOutOfRange() throws {
        var game = makeSingleEntityGame(
            houseIndex: 0, unitIndex: 0, unitType: 0, unitHouse: 0,
            structIndex: 0, structType: 0, structHouse: 0
        )
        let bad = makeStructureRecord(index: 200, type: 0, houseID: 0)
        game = replacingStructures(game, with: Formats.Save.Structures(slots: [bad]))
        let baseline = makeBaseline(groundTileID: 0)
        #expect(throws: Simulation.WorldSnapshot.LoadError.structureIndexOutOfRange(200)) {
            _ = try Simulation.WorldSnapshot(loading: game, baseline: baseline)
        }
    }

    // (Baseline size is guarded by `Map.init`'s precondition, so we don't
    // need a WorldSnapshot-layer check.)

    // MARK: Real data

    @Test("_SAVE001.DAT loads end-to-end into populated pools + dense tile grid")
    func realSave001() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let game = try Formats.Save.Game.decode(data)

        // Pick an arbitrary baseline — WorldSnapshot doesn't care about terrain
        // accuracy, only cell count. A generator-accurate baseline would be
        // `Map.Generator.generate(seed: game.info.scenario.mapSeed, …)`.
        let baseline = Map.empty()
        let snap = try Simulation.WorldSnapshot(loading: game, baseline: baseline)

        // Houses: allocated slots match the record count, humanSlot is present.
        #expect(snap.houses.findArray.count == game.houses.slots.count)
        if let human = game.houses.humanSlot {
            let idx = Int(human.index)
            #expect(snap.houses[idx].isUsed)
        }

        // Units: every record appears in findArray.
        #expect(snap.units.findArray.count == game.units.slots.count)
        for slot in game.units.slots {
            let idx = Int(slot.object.index)
            #expect(snap.units[idx].isUsed)
            #expect(snap.units[idx].type == slot.object.type)
            #expect(snap.units[idx].houseID == slot.object.houseID)
        }

        // Structures: every record appears in findArray (none land in reserved slots).
        #expect(snap.structures.findArray.count == game.structures.slots.count)
        for slot in game.structures.slots {
            let idx = Int(slot.object.index)
            #expect(snap.structures[idx].isUsed)
        }

        // Tiles: exactly 4096 entries; every sparse override is visible.
        #expect(snap.tiles.count == 4096)
        for entry in game.tileMap.entries {
            let idx = Int(entry.cellIndex)
            #expect(snap.tiles[idx].groundTileID == entry.tile.groundTileID)
            #expect(snap.tiles[idx].isUnveiled == entry.tile.isUnveiled)
            #expect(snap.tiles[idx].hasStructure == entry.tile.hasStructure)
            #expect(snap.tiles[idx].objectRef == entry.tile.tileIndex)
        }
    }

    @Test("init(scenario:resolver:) allocates one pool slot per spawn with OpenDUNE IDs")
    func scenarioSnapshotPoolAllocation() throws {
        // Build a synthetic scenario directly, bypassing the INI parser so
        // this test runs without the install.
        var scenario = Scenario()
        scenario.mapField.seed = 0x1234
        scenario.houses[.atreides] = Scenario.HouseLayout()
        scenario.houses[.harkonnen] = Scenario.HouseLayout()
        scenario.units = [
            .init(id: "Unit000", house: .atreides, unitType: .mcv, hitPoints: 100,
                  position: PackedPosition(raw: 0x0403), orientation: 64, action: .guard_),
            .init(id: "Unit001", house: .harkonnen, unitType: .tank, hitPoints: 200,
                  position: PackedPosition(raw: 0x1020), orientation: 0, action: .hunt)
        ]
        scenario.structures = [
            .init(id: "Structure000", house: .atreides, structureType: .constructionYard,
                  hitPoints: 500, position: PackedPosition(raw: 0x0403), isGenerated: false),
            .init(id: "GEN0050", house: .atreides, structureType: .slab1x1,
                  hitPoints: 50, position: PackedPosition(raw: 50), isGenerated: true)
        ]

        let resolver = TileResolver(iconMap: try syntheticIconMap())
        let snap = try Simulation.WorldSnapshot(scenario: scenario, resolver: resolver)

        // Houses: one slot allocated per key in `scenario.houses`.
        #expect(snap.houses.findArray.count == 2)
        #expect(snap.houses[1].isUsed)   // Atreides typeID == 1
        #expect(snap.houses[0].isUsed)   // Harkonnen typeID == 0

        // Units: two allocated in spawn order, at slots 0 and 1.
        #expect(snap.units.findArray == [0, 1])
        #expect(snap.units[0].type == 17)           // MCV
        #expect(snap.units[0].houseID == 1)         // Atreides
        #expect(snap.units[0].orientationCurrent == 64)
        #expect(snap.units[1].type == 9)            // Tank
        #expect(snap.units[1].houseID == 0)         // Harkonnen
        #expect(snap.units[1].orientationCurrent == 0)

        // Structures: one allocated (GEN-slab is skipped).
        #expect(snap.structures.findArray == [0])
        #expect(snap.structures[0].type == 8)       // Construction Yard
        #expect(snap.structures[0].houseID == 1)

        // Tiles: generated from the seed, not empty.
        #expect(snap.tiles.count == 4096)
        #expect(snap.tiles[0].groundTileID != 0)
    }

    @Test("init(loading:resolver:) runs Map.Generator with the save's mapSeed")
    func resolverConvenienceMatchesExplicitBaseline() throws {
        guard let installRoot = TestInstall.locate() else { return }
        let savePath = installRoot.appendingPathComponent("_SAVE001.DAT")
        let iconPak = installRoot.appendingPathComponent("DUNE.PAK")
        guard FileManager.default.fileExists(atPath: savePath.path),
              FileManager.default.fileExists(atPath: iconPak.path) else { return }

        let game = try Formats.Save.Game.decode(Data(contentsOf: savePath))
        let archive = try Formats.Pak.Archive(contentsOf: iconPak)
        guard let iconBody = archive.body(named: "ICON.MAP") else { return }
        let resolver = TileResolver(iconMap: try Formats.IconMap.decode(iconBody))

        let convenience = try Simulation.WorldSnapshot(loading: game, resolver: resolver)

        let explicitBaseline = Map.Generator.generate(
            seed: game.info.scenario.mapSeed, resolver: resolver
        )
        let explicit = try Simulation.WorldSnapshot(loading: game, baseline: explicitBaseline)

        // Pools are driven entirely by the save records, so they should match
        // bit-for-bit regardless of baseline.
        #expect(convenience.houses == explicit.houses)
        #expect(convenience.units == explicit.units)
        #expect(convenience.structures == explicit.structures)
        // And so should every tile — convenience = explicit by construction.
        #expect(convenience.tiles == explicit.tiles)
        // Spot-check at cell 0 that the ground tile is actually terrain-generated
        // (non-zero), distinguishing this from `Map.empty()` baselines.
        #expect(convenience.tiles[0].groundTileID != 0)
    }
}

// MARK: - Save.Game builders (pure composition over decoded values)

private func makeSingleEntityGame(
    houseIndex: UInt16,
    unitIndex: UInt16, unitType: UInt8, unitHouse: UInt8,
    structIndex: UInt16, structType: UInt8, structHouse: UInt8
) -> Formats.Save.Game {
    let info = minimalInfo()
    let house = Formats.Save.Player.HouseSlot(
        index: houseIndex, harvestersIncoming: 0,
        flags: Formats.Save.Player.HouseFlags(rawWord: 0x01 | 0x02),
        unitCount: 0, unitCountMax: 0, unitCountEnemy: 0, unitCountAllied: 0,
        structuresBuilt: 0,
        credits: 0, creditsStorage: 0, powerProduction: 0, powerUsage: 0,
        windtrapCount: 0, creditsQuota: 0,
        palacePositionX: 0, palacePositionY: 0,
        timerUnitAttack: 0, timerSandwormAttack: 0, timerStructureAttack: 0,
        starportTimeLeft: 0, starportLinkedID: 0xFFFF,
        aiStructureRebuild: [UInt16](repeating: 0, count: 10)
    )
    let unit = makeUnitRecord(index: unitIndex, type: unitType, houseID: unitHouse)
    let struc = makeStructureRecord(index: structIndex, type: structType, houseID: structHouse)
    return Formats.Save.Game(
        description: "test",
        info: info,
        houses: Formats.Save.Player(slots: [house]),
        units: Formats.Save.Units(slots: [unit]),
        structures: Formats.Save.Structures(slots: [struc]),
        tileMap: Formats.Save.TileMap(entries: []),
        team: nil,
        unitsNew: nil
    )
}

private func makeBaseline(groundTileID: UInt16) -> Map {
    Map(cells: Array(repeating: Map.Cell(groundTileID: groundTileID), count: 4096))
}

private func minimalInfo() -> Formats.Save.Info {
    // Decode a zero-payload 330-byte body so every field defaults cleanly.
    var body = Data()
    body.append(0x90); body.append(0x02) // version 0x0290
    body.append(Data(count: 328))
    return try! Formats.Save.Info.decode(body)
}

private func makeUnitRecord(index: UInt16, type: UInt8, houseID: UInt8) -> Formats.Save.Units.Slot {
    Formats.Save.Units.Slot(
        object: Formats.Save.ObjectHeader(
            index: index, type: type, linkedID: 0xFF,
            flags: Formats.Save.ObjectFlags(rawDword: 0x01 | 0x010000),
            houseID: houseID, seenByHouses: 0,
            positionX: 0, positionY: 0, hitpoints: 1,
            script: emptyScriptState()
        ),
        currentDestinationX: 0, currentDestinationY: 0, originEncoded: 0,
        actionID: 0, nextActionID: 0, fireDelay: 0,
        distanceToDestination: 0, targetAttack: 0, targetMove: 0,
        amount: 0, deviated: 0,
        targetLastX: 0, targetLastY: 0, targetPreLastX: 0, targetPreLastY: 0,
        orientation: [
            .init(speed: 0, target: 0, current: 0),
            .init(speed: 0, target: 0, current: 0)
        ],
        speedPerTick: 0, speedRemainder: 0, speed: 0, movingSpeed: 0,
        wobbleIndex: 0, spriteOffset: 0, blinkCounter: 0, team: 0,
        timer: 0,
        route: [UInt8](repeating: 0, count: 14)
    )
}

private func makeStructureRecord(index: UInt16, type: UInt8, houseID: UInt8) -> Formats.Save.Structures.Slot {
    Formats.Save.Structures.Slot(
        object: Formats.Save.ObjectHeader(
            index: index, type: type, linkedID: 0xFF,
            flags: Formats.Save.ObjectFlags(rawDword: 0x01),
            houseID: houseID, seenByHouses: 0,
            positionX: 0, positionY: 0, hitpoints: 1,
            script: emptyScriptState()
        ),
        creatorHouseID: 0, rotationSpriteDiff: 0,
        objectType: 0, upgradeLevel: 0, upgradeTimeLeft: 0,
        countDown: 0, buildCostRemainder: 0, state: 0, hitpointsMax: 1
    )
}

private func emptyScriptState() -> Formats.Save.ScriptState {
    Formats.Save.ScriptState(
        delay: 0, scriptOffset: 0, returnValue: 0,
        framePointer: 0, stackPointer: 0,
        variables: [UInt16](repeating: 0, count: 5),
        stack: [UInt16](repeating: 0, count: 15),
        isSubroutine: 0
    )
}

// MARK: Game field-replacement helpers (Game is let-only; rebuild with replacements)

private func replacingPlayer(_ g: Formats.Save.Game, with p: Formats.Save.Player) -> Formats.Save.Game {
    .init(description: g.description, info: g.info, houses: p, units: g.units,
          structures: g.structures, tileMap: g.tileMap, team: g.team, unitsNew: g.unitsNew)
}
private func replacingUnits(_ g: Formats.Save.Game, with u: Formats.Save.Units) -> Formats.Save.Game {
    .init(description: g.description, info: g.info, houses: g.houses, units: u,
          structures: g.structures, tileMap: g.tileMap, team: g.team, unitsNew: g.unitsNew)
}
private func replacingStructures(_ g: Formats.Save.Game, with s: Formats.Save.Structures) -> Formats.Save.Game {
    .init(description: g.description, info: g.info, houses: g.houses, units: g.units,
          structures: s, tileMap: g.tileMap, team: g.team, unitsNew: g.unitsNew)
}
private func replacingTileMap(_ g: Formats.Save.Game, with t: Formats.Save.TileMap) -> Formats.Save.Game {
    .init(description: g.description, info: g.info, houses: g.houses, units: g.units,
          structures: g.structures, tileMap: t, team: g.team, unitsNew: g.unitsNew)
}

/// IconMap with an 81-entry LANDSCAPE group — exactly what `Map.Generator`
/// needs. Other groups are stubbed. Reused from `MapGeneratorTests`.
func syntheticIconMap() throws -> Formats.IconMap {
    var u16s: [UInt16] = Array(repeating: 28, count: 28)
    u16s[6] = 28   // WALLS
    u16s[7] = 60   // FOG_OF_WAR
    u16s[8] = 92   // CONCRETE_SLAB
    u16s[9] = 124  // LANDSCAPE (81 entries)
    u16s[10] = 205 // SPICE_BLOOM
    for i in 11..<27 { u16s[i] = 237 }
    u16s[27] = 237
    func run(_ startId: UInt16, _ count: Int) -> [UInt16] {
        (0..<count).map { UInt16(Int(startId) + $0) }
    }
    u16s.append(contentsOf: run(4000, 32))
    u16s.append(contentsOf: run(5000, 32))
    u16s.append(contentsOf: run(3000, 32))
    u16s.append(contentsOf: run(1000, 81))
    u16s.append(contentsOf: run(2000, 32))
    var data = Data()
    for v in u16s {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }
    return try Formats.IconMap.decode(data)
}
