import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld

/// Loads a real committed scenario `.INI` (+ `ICON.MAP`) into a `GameState` and checks the map +
/// objects are populated. SCENA001 = Atreides mission 1 (`[MAP] Seed=353`, `[BASIC] MapScale=1`).
@Suite("Scenario loader")
struct ScenarioLoaderTests {
    @Test("SCENA001 loads landscape + units + structures")
    func loadScena001() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let ini = try Ini(Data(contentsOf: root.appendingPathComponent("Resources/Scenarios/SCENA001.INI")))

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)

        #expect(state.mapScale == 1)
        #expect(state.tileIDs.landscape == 127)
        // Landscape was generated (not all tiles are the same sprite).
        #expect(Set(state.map.map(\.groundTileID)).count > 1)
        // Units placed (the file has an Atreides Trike + soldiers, an Ordos squad, …).
        #expect(state.unitFindArray.count > 3)
        let trike = state.units.first { $0.o.flags.contains(.used) && $0.o.type == UInt8(UnitType.trike.rawValue) }
        let placedTrike = try #require(trike)
        #expect(placedTrike.o.position == Tile32.unpack(1501))
        // A construction yard structure (ID000=Atreides,Const Yard,256,1630).
        let cy = state.structures.first {
            $0.o.flags.contains(.used) && $0.o.type == UInt8(StructureType.constructionYard.rawValue)
        }
        #expect(cy != nil)
        // A structure stores its tile *corner* (the 0x80 sub-tile stripped), not the centred unpack
        // (`Structure_Place`: `position &= 0xFF00`) — units centre, structures don't.
        #expect(cy?.o.position == Tile32(x: Tile32.unpack(1630).x & 0xFF00, y: Tile32.unpack(1630).y & 0xFF00))
        #expect(cy?.o.position.packed == 1630)   // same packed tile either way
    }

    @Test("SCENA001 seeds house credits + the player from the per-house sections")
    func loadHouses() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let ini = try Ini(Data(contentsOf: root.appendingPathComponent("Resources/Scenarios/SCENA001.INI")))

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)

        // [Atreides] Brain=Human Credits=1000 Quota=1000 MaxUnit=25 → the player house.
        let atreides = Int(HouseID.atreides.rawValue)
        #expect(state.houses[atreides].flags.contains(.used))
        #expect(state.houses[atreides].credits == 1000)
        #expect(state.houses[atreides].creditsQuota == 1000)
        #expect(state.houses[atreides].unitCountMax == 25)
        #expect(state.playerHouseID == UInt8(HouseID.atreides.rawValue))
        // The no-silo allowance = the player's starting credits, so the house-tick clamp keeps them.
        #expect(state.playerCreditsNoSilo == 1000)
        // The Brain=Human house is flagged `.human` (`Scenario_Load_House`, scenario.c:74). Without it the
        // human-only gates misfire — e.g. the palace auto-fire (`!human && isAIActive`) launches the player's
        // own house missile at scenario start. The CPU house must NOT be human.
        #expect(state.houses[atreides].flags.contains(.human))
        // [Ordos] Brain=CPU is allocated too (so GameLoop_House runs it), and is not human.
        #expect(state.houses[Int(HouseID.ordos.rawValue)].flags.contains(.used))
        #expect(!state.houses[Int(HouseID.ordos.rawValue)].flags.contains(.human))
    }

    @Test("SCENA001 places its [MAP] Bloom spice bloom + loads the WinFlags/LoseFlags")
    func loadMapBloomAndFlags() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let ini = try Ini(Data(contentsOf: root.appendingPathComponent("Resources/Scenarios/SCENA001.INI")))

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)

        // [MAP] Bloom=2409 → that tile shows the spice-bloom sprite…
        #expect(state.tileIDs.bloom != 0)
        #expect(state.map[2409].groundTileID == state.tileIDs.bloom)
        // …but its BASE tile stays the generated sand, not the bloom — otherwise `Map_Bloom_ExplodeSpice`
        // (which reverts groundTileID to `mapBaseTileID & 0x1FF`) would restore the bloom and it would never
        // disappear when a unit detonates it.
        #expect(state.mapBaseTileID[2409] & 0x1FF != state.tileIDs.bloom)
        // [BASIC] WinFlags/LoseFlags loaded; the level starts in progress.
        #expect(state.scenario.winFlags != 0)
        #expect(state.gameEndState == .playing)
        #expect(state.tickScenarioStart == 0)
    }

    @Test("[REINFORCEMENTS] + [CHOAM] are parsed into the timed-spawn table + starport stock")
    func loadReinforcementsAndChoam() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let text = """
        [BASIC]
        MapScale=0
        [MAP]
        Seed=353
        [Atreides]
        Brain=Human
        Credits=1000
        [REINFORCEMENTS]
        0=Atreides,Trike,West,5
        1=Ordos,Quad,Air,10+
        [CHOAM]
        Trike=5
        Quad=3
        """
        let ini = try Ini(Data(text.utf8))

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)

        // Entry 0: a West-edge Atreides Trike; timeBetween = atoi(5)*6+1 = 31; never repeats.
        let r0 = state.scenario.reinforcements[0]
        #expect(r0.unitType == UInt8(UnitType.trike.rawValue))
        #expect(r0.houseID == UInt8(HouseID.atreides.rawValue))
        #expect(r0.locationID == 3)              // WEST
        #expect(r0.timeBetween == 31)
        #expect(r0.timeLeft == 31)
        #expect(r0.repeats == false)
        // Entry 1: an Air Ordos Quad; the trailing '+' is dropped in 1.07 (no repeat).
        let r1 = state.scenario.reinforcements[1]
        #expect(r1.unitType == UInt8(UnitType.quad.rawValue))
        #expect(r1.locationID == 4)              // AIR
        #expect(r1.timeBetween == 61)
        #expect(r1.repeats == false)
        // [CHOAM] seeds the starport stock.
        #expect(state.starportAvailable[UnitType.trike.rawValue] == 5)
        #expect(state.starportAvailable[UnitType.quad.rawValue] == 3)
    }

    @Test("[MAP] Field tiles are stashed in scenario.spiceFields (the sim fills them)")
    func loadMapField() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let text = """
        [BASIC]
        MapScale=1
        [MAP]
        Seed=353
        Field=1234,2500
        """
        let ini = try Ini(Data(text.utf8))

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)
        #expect(state.scenario.spiceFields == [1234, 2500])
    }
}
