import AppKit
import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation

/// The render-golden harness: load the original install, run a scenario to a tick through the **real**
/// simulation, then capture a (cropped) frame through the **real** `SpriteKitRenderer` — the same nodes,
/// textures, z-order, palette and fog the on-screen app uses. The capture is GPU-backed, so it returns
/// `nil` on a box with no off-screen graphics context (the test then short-circuits, like the install-
/// absent path). Mirrors the `rendercap` tool's setup so a reference captured here matches the app.
enum RenderHarness {
    /// The original 1.07 install (`Repositories/patched_107_unofficial`), four directories up from this
    /// source file (`Code/Tests/RenderGoldenTests/RenderHarness.swift`), or `nil` when absent.
    static var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The `Fixtures/` directory holding the committed reference PNGs (next to this file).
    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures",
            isDirectory: true
        )
    }

    /// One render-golden case: a scenario advanced to `tick`, captured at a tile-space `rect` (`nil` = the
    /// whole 64×64 map), optionally with fog of war shown.
    struct Case: Sendable {
        let name: String
        let scenario: String
        let tick: Int
        let rect: (x: Int, y: Int, w: Int, h: Int)?
        let fog: Bool
        /// Drop a stationary sandworm at this tile before rendering (to exercise the shimmer); `nil` = none.
        let worm: (x: Int, y: Int)?
        /// Drop a stationary ornithopter at this tile (to exercise the winger drop shadow); `nil` = none.
        let air: (x: Int, y: Int)?

        init(
            _ name: String,
            scenario: String,
            tick: Int,
            rect: (x: Int, y: Int, w: Int, h: Int)? = nil,
            fog: Bool = false,
            worm: (x: Int, y: Int)? = nil,
            air: (x: Int, y: Int)? = nil
        ) {
            self.name = name
            self.scenario = scenario
            self.tick = tick
            self.rect = rect
            self.fog = fog
            self.worm = worm
            self.air = air
        }
    }

    /// A prepared render-golden case: the live renderer + the frame to draw, plus the terrain tile size for
    /// cropping. Lets a test render the same frame repeatedly (e.g. to exercise the shimmer throttle).
    @MainActor
    struct Prepared {
        let renderer: SpriteKitRenderer
        let frame: FrameInfo
        let tileSize: Int
    }

    /// Render `c` to a `CGImage`, or `nil` when the install is absent or no GPU context is available.
    /// `@MainActor` — drives the SpriteKit renderer.
    @MainActor
    static func capture(_ c: Case) -> CGImage? {
        guard let p = prepare(c) else { return nil }

        let crop = c.rect.map {
            CGRect(
                x: $0.x * p.tileSize,
                y: $0.y * p.tileSize,
                width: $0.w * p.tileSize,
                height: $0.h * p.tileSize
            )
        }
        return p.renderer.snapshot(p.frame, crop: crop)
    }

    /// Build the simulation + renderer for `c` without capturing — the shared setup behind `capture`, also
    /// used by the shimmer-throttle test. `nil` when the install is absent.
    @MainActor
    static func prepare(_ c: Case) -> Prepared? {
        guard
            let installURL,
            let assets = Assets(installURL: installURL),
            let ini = assets.ini(c.scenario)
        else { return nil }

        // Build + run the simulation to `c.tick` (mirrors rendercap / mapview setup).
        var state = GameState()
        state.loadScenario(ini: ini, iconMap: assets.iconMap)
        for h in 0 ..< 6 { _ = state.houseAllocate(index: UInt8(h)); state.houses[h].unitCountMax = 1000 }
        state.viewportPosition = Tile32.packXY(x: 32, y: 32)

        let unitScript = ScriptInfo(assets.unitProgram)
        let setup = UnitActions()
        for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
            setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: unitScript, in: &state)
            state.unitUpdateMap(1, slot)
        }

        // Optionally drop a stationary sandworm (no script → it sits) to exercise the shimmer.
        if let w = c.worm, let slot = state.units.firstIndex(where: { !$0.o.flags.contains(.used) }) {
            var worm = Unit()
            worm.o.index = UInt16(slot)
            worm.o.type = UInt8(UnitType.sandworm.rawValue)
            worm.o.flags = [ .used, .allocated, .isUnit ]
            worm.o.houseID = 6
            worm.o.position = Tile32(x: UInt16(w.x) * 256 + 0x80, y: UInt16(w.y) * 256 + 0x80)
            worm.o.hitpoints = 1000
            state.units[slot] = worm
        }

        // Optionally drop a stationary ornithopter (a `hasShadow` winger, no script → it sits) to exercise the
        // drop-shadow pass. Captured at tick 0 so the sim never moves it off the building beneath it.
        if let a = c.air, let slot = state.units.firstIndex(where: { !$0.o.flags.contains(.used) }) {
            var thopter = Unit()
            thopter.o.index = UInt16(slot)
            thopter.o.type = UInt8(UnitType.ornithopter.rawValue)
            thopter.o.flags = [ .used, .allocated, .isUnit ]
            thopter.o.houseID = 0
            thopter.o.position = Tile32(x: UInt16(a.x) * 256 + 0x80, y: UInt16(a.y) * 256 + 0x80)
            thopter.o.hitpoints = 100
            state.units[slot] = thopter
        }

        var sim = Simulation(
            state: state,
            scriptInfo: unitScript,
            structureScriptInfo: ScriptInfo(assets.buildProgram),
            tickExplosions: true,
            tickAnimations: true
        )
        for _ in 0 ..< max(0, c.tick) { sim.tick() }

        // A graphics-session connection for off-screen SpriteKit rendering, without showing a window.
        NSApplication.shared.setActivationPolicy(.accessory)
        let renderer = SpriteKitRenderer(source: assets.spriteSource, basePalette: assets.palette, showFog: c.fog)
        return Prepared(renderer: renderer, frame: sim.makeFrameInfo(), tileSize: assets.spriteSource.terrainTileSize)
    }
}

/// Loads the assets the renderer + sim need from the install PAKs (mirrors `rendercap`'s `Assets`).
private struct Assets {
    let palette: Palette
    let iconMap: IconMap
    let spriteSource: DecodedSpriteSource
    let unitProgram: Emc.Program
    let buildProgram: Emc.Program
    private let archives: [Pak.Archive]

    init?(installURL: URL) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(at: installURL, includingPropertiesForKeys: nil)
        else { return nil }

        var archives: [Pak.Archive] = []
        for url in entries where url.pathExtension.uppercased() == "PAK" {
            if let data = try? Data(contentsOf: url), let archive = try? Pak.Archive(data) { archives.append(archive) }
        }
        self.archives = archives

        func data(_ name: String) -> Data? {
            for a in archives {
                if let e = a.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    return a.data(e)
                }
            }
            return nil
        }

        guard
            let pal = data("IBM.PAL").flatMap({ try? Palette($0) }),
            let map = data("ICON.MAP").flatMap({ try? IconMap($0) }),
            let icn = data("ICON.ICN").flatMap({ try? Icn.TileSet($0) }),
            let unit = data("UNIT.EMC").flatMap({ try? Emc.Program($0) }),
            let build = data("BUILD.EMC").flatMap({ try? Emc.Program($0) })
        else { return nil }

        var sheets: [String: Shp.FrameSet] = [:]
        for sheet in UnitSpriteSheet.allCases where sheets[sheet.fileName] == nil {
            if let s = data(sheet.fileName).flatMap({ try? Shp.FrameSet($0) }) { sheets[sheet.fileName] = s }
        }

        palette = pal
        iconMap = map
        spriteSource = DecodedSpriteSource(tileSet: icn, sheets: sheets)
        unitProgram = unit
        buildProgram = build
    }

    func ini(_ name: String) -> Ini? {
        for a in archives {
            if let e = a.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return Ini(a.data(e))
            }
        }
        return nil
    }
}
