import AppKit
import CoreGraphics
import DuneIIContracts
import DuneIIExport
import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation

/// A tiny headless capture tool to prove the real renderer can snapshot to a file off-screen: load the
/// install, run a scenario to a given tick, swap in a `SpriteKitRenderer`, capture a (cropped) region with
/// `snapshot(_:crop:)`, and write a PNG. Usage:
///
///   swift run rendercap <installDir> [--scenario NAME] [--tick N] [--rect x,y,w,h] [--fog] [--out FILE]
///
/// `installDir` is the original 1.07 install (the dir holding the `.PAK`s). `--rect` is in **tiles**
/// (default: the whole 64×64 map). Defaults: first scenario, tick 0, `snapshot.png` in the CWD.
@main
enum RenderCap {
    @MainActor
    static func main() {
        note("start")
        // A graphics-session connection for off-screen SpriteKit rendering, without showing a window.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        note("NSApplication ok")

        let args = Args(CommandLine.arguments)
        guard
            let installDir = args.positional.first
        else {
            fail("usage: rendercap <installDir> [--scenario NAME] [--tick N] [--rect x,y,w,h] [--fog] [--out FILE]")
        }
        let installURL = URL(fileURLWithPath: installDir)

        guard
            let assets = Assets(installURL: installURL)
        else {
            fail(
                "could not load PAK assets from \(installDir) (need IBM.PAL, ICON.MAP, ICON.ICN, UNIT/BUILD.EMC, a SCEN*.INI)"
            )
        }

        let scenarioName = args.value("--scenario") ?? assets.scenarioNames.first
        guard
            let scenarioName,
            let ini = assets.ini(scenarioName)
        else {
            fail("no scenario (available: \(assets.scenarioNames.prefix(5).joined(separator: ", "))…)")
        }

        let tick = args.value("--tick").flatMap { Int($0) } ?? 0
        let out = URL(fileURLWithPath: args.value("--out") ?? "snapshot.png")
        let crop = args.value("--rect").flatMap(parseRect)  // in tiles

        // Build + run the simulation to `tick` (mirrors mapview's setup).
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

        // Debug: drop a stationary sandworm at a tile to exercise the shimmer (`--worm tx,ty`). Injected
        // after unit setup + with no script, so it sits still (use with `--tick 0`).
        if let w = args.value("--worm").flatMap(parsePair),
            let slot = state.units.firstIndex(where: { !$0.o.flags.contains(.used) })
        {
            var worm = Unit()
            worm.o.index = UInt16(slot)
            worm.o.type = UInt8(UnitType.sandworm.rawValue)
            worm.o.flags = [ .used, .allocated, .isUnit ]
            worm.o.houseID = 6
            worm.o.position = Tile32(x: UInt16(w.x) * 256 + 0x80, y: UInt16(w.y) * 256 + 0x80)
            worm.o.hitpoints = 1000
            state.units[slot] = worm
        }

        var sim = Simulation(
            state: state,
            scriptInfo: unitScript,
            structureScriptInfo: ScriptInfo(assets.buildProgram),
            tickExplosions: true,
            tickAnimations: true
        )
        for _ in 0 ..< max(0, tick) { sim.tick() }
        note("ticked to \(tick)")

        // Swap in the real renderer just for the capture.
        let renderer = SpriteKitRenderer(
            source: assets.spriteSource,
            basePalette: assets.palette,
            showFog: args.flag("--fog")
        )
        note("renderer built; capturing")
        let ts = assets.spriteSource.terrainTileSize
        let cropRect = crop.map { CGRect(x: $0.x * ts, y: $0.y * ts, width: $0.w * ts, height: $0.h * ts) }

        let frameInfo = sim.makeFrameInfo()
        for b in frameInfo.blurs {
            note(
                "blur at world (\(b.positionX),\(b.positionY)) sprite #\(b.sprite.spriteIndex) "
                    + "resolves=\(assets.spriteSource.unitFrame(globalIndex: b.sprite.spriteIndex) != nil)"
            )
        }
        guard
            let image = renderer.snapshot(frameInfo, crop: cropRect)
        else {
            fail("snapshot returned nil — no off-screen GPU/graphics context available here")
        }

        do {
            try PngWriter.write(image: image, to: out)
            print(
                "rendercap: wrote \(image.width)×\(image.height) → \(out.path) "
                    + "(scenario \(scenarioName), tick \(tick)\(crop.map { _ in ", cropped" } ?? "")\(args.flag("--fog") ? ", fog" : ""))"
            )
        } catch {
            fail("write failed: \(error)")
        }
    }

    static func parseRect(_ s: String) -> (x: Int, y: Int, w: Int, h: Int)? {
        let p = s.split(separator: ",").compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        return (p[0], p[1], p[2], p[3])
    }

    static func parsePair(_ s: String) -> (x: Int, y: Int)? {
        let p = s.split(separator: ",").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return (p[0], p[1])
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("rendercap: " + message + "\n").utf8))
        exit(1)
    }

    /// Progress to stderr so a crash localizes to the last printed stage.
    static func note(_ s: String) {
        FileHandle.standardError.write(Data(("rendercap: [stage] " + s + "\n").utf8))
    }
}

/// Minimal positional/flag arg parsing.
private struct Args {
    let positional: [String]
    private let values: [String: String]
    private let flags: Set<String>

    init(_ argv: [String]) {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var i = 1
        let known = Set([ "--scenario", "--tick", "--rect", "--out", "--worm" ])
        while i < argv.count {
            let a = argv[i]
            if known.contains(a), i + 1 < argv.count {
                values[a] = argv[i + 1]; i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a); i += 1
            } else {
                positional.append(a); i += 1
            }
        }
        self.positional = positional
        self.values = values
        self.flags = flags
    }

    func value(_ key: String) -> String? { values[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

/// Loads the assets the renderer + sim need from the install PAKs (mirrors mapview's `AssetStore`).
private struct Assets {
    let palette: Palette
    let iconMap: IconMap
    let spriteSource: DecodedSpriteSource
    let unitProgram: Emc.Program
    let buildProgram: Emc.Program
    let scenarioNames: [String]
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

        var names = Set<String>()
        for a in archives {
            for e in a.entries where e.name.uppercased().hasPrefix("SCEN") && e.name.uppercased().hasSuffix(".INI") {
                names.insert(e.name.uppercased())
            }
        }
        guard !names.isEmpty else { return nil }

        palette = pal
        iconMap = map
        spriteSource = DecodedSpriteSource(tileSet: icn, sheets: sheets)
        unitProgram = unit
        buildProgram = build
        scenarioNames = names.sorted()
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
