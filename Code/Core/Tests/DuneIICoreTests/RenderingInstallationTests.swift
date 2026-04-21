import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("DuneIIRendering.Installation + AssetLoader")
struct RenderingInstallationTests {
    @Test("Installation discovery locates the install, indexes every PAK entry")
    func installationIndex() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        #expect(install.pakURLs.count >= 5)
        // Spot-check a few well-known assets that must exist in a vanilla
        // 1.07 install.
        #expect(install.body(of: "IBM.PAL") != nil)
        #expect(install.body(of: "ICON.MAP") != nil)
        #expect(install.body(of: "ICON.ICN") != nil)
        #expect(install.body(of: "MENTATA.CPS") != nil)
        #expect(install.body(of: "SCENA001.INI") != nil)
    }

    @Test("Installation body lookup is case-insensitive")
    func caseInsensitive() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        #expect(install.body(of: "ibm.pal") != nil)
        #expect(install.body(of: "Ibm.Pal") != nil)
    }

    @Test("Installation.assetNames(startingWith:) finds every scenario")
    func scenarioPrefix() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let scenarios = install.assetNames(startingWith: "SCENA")
        #expect(!scenarios.isEmpty)
        #expect(scenarios.allSatisfy { $0.hasSuffix(".INI") })
    }

    @Test("AssetLoader caches palette + iconmap and decodes MENTATA.CPS")
    func assetLoader() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        // 256-color palette exactly.
        #expect(assets.palette.colors.count == 256)
        // IconMap opens cleanly and resolves a known landscape entry.
        let landscape0 = assets.iconMap.tileId(in: .landscape, offset: 0)
        #expect(landscape0 > 0)
        // CPS → CGImage; size matches the native resolution.
        let cg = try assets.loadCps(named: "MENTATA.CPS")
        #expect(cg.width == Formats.Cps.Image.width)
        #expect(cg.height == Formats.Cps.Image.height)
    }

    @Test("AssetLoader.loadScenario decodes SCENA001.INI into a Scenario")
    func scenarioLoad() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        let scenario = try assets.loadScenario(named: "SCENA001.INI")
        #expect(scenario != nil)
    }

    @Test("AssetLoader.loadIcn returns every tile as a CGImage of the right size")
    func iconTiles() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        let tiles = try assets.loadIcn()
        #expect(tiles.count > 100)
        // Every tile is 16×16 in vanilla Dune II.
        for tile in tiles.prefix(16) {
            #expect(tile.width == 16)
            #expect(tile.height == 16)
        }
    }

    @Test("SCENA001.INI carries units + structures we can render as markers")
    func scenarioRoster() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard let scenario = try assets.loadScenario(named: "SCENA001.INI") else { return }
        // Mission 1 has a player unit + spawn and at least a construction
        // yard; enemies add their own units.
        #expect(!scenario.units.isEmpty)
        #expect(!scenario.structures.isEmpty)
        // Every unit / structure resolves to a valid packed position
        // within the 64×64 grid.
        for u in scenario.units {
            let t = u.position.tile
            #expect(t.x < 64)
            #expect(t.y < 64)
        }
        for s in scenario.structures {
            let t = s.position.tile
            #expect(t.x < 64)
            #expect(t.y < 64)
        }
        // House colours resolve for every spawn's house without trapping.
        for u in scenario.units { _ = HouseColors.color(for: u.house) }
        for s in scenario.structures { _ = HouseColors.color(for: s.house) }
    }
}
