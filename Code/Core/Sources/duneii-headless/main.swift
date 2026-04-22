import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import DuneIICore
import DuneIIRendering
import AssetExport
import Memoirs

// duneii-headless — stdin-driven headless driver for ScenarioRuntime.
//
// Reads one command per line on stdin; prints results on stdout (one
// line per command, prefixed with `ok ` on success or `! ` on error);
// Log facade output goes to stderr. Redirect stderr to a file to keep
// stdout clean for parsing.
//
// Run: `swift run duneii-headless`
// Example:
//   load SCENA001
//   dump structures
//   tick 200
//   dump build
//   quit

@MainActor
final class Harness {
    private let runtime: ScenarioRuntime
    private let out = FileHandle.standardOutput

    init() {
        #if DEBUG
        let stderrMemoir = FileMemoir(handle: FileHandle.standardError)
        let minLevel: FilteringMemoir.Configuration.Level =
            (ProcessInfo.processInfo.environment["DUNEII_LOG_VERBOSE"] == "1")
            ? .verbose : .debug
        let filtered = FilteringMemoir(
            memoir: stderrMemoir,
            defaultConfiguration: .init(minLevelShown: minLevel)
        )
        Log.setup(memoir: filtered)
        #endif

        guard let installDir = Installation.discover() else {
            FileHandle.standardError.write(Data("! no install found; run from project tree\n".utf8))
            exit(2)
        }
        do {
            let installation = try Installation(rootDirectory: installDir)
            let assets = try AssetLoader(installation: installation)
            self.runtime = ScenarioRuntime(assets: assets)
        } catch {
            FileHandle.standardError.write(Data("! failed to open install: \(error)\n".utf8))
            exit(2)
        }
    }

    func run() {
        writeLine("# duneii-headless ready. type 'help' or 'quit'.")
        while let raw = readLine(strippingNewline: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(separator: " ").map(String.init)
            guard let cmd = tokens.first else { continue }
            let args = Array(tokens.dropFirst())
            handle(cmd: cmd, args: args)
        }
    }

    private func handle(cmd: String, args: [String]) {
        switch cmd {
        case "help":
            for l in Self.helpText { writeLine(l) }
        case "quit", "exit":
            writeLine("# bye")
            exit(0)
        case "load":
            guard let name = args.first else { writeLine("! usage: load <scenario>"); return }
            do {
                try runtime.load(scenarioName: name)
                writeLine("ok load \(name) tick=\(runtime.tickCounter) selectedYard=\(runtime.buildController.selectedYardIndex ?? -1)")
            } catch {
                writeLine("! load \(error)")
            }
        case "tick":
            let n = (args.first.flatMap { Int($0) }) ?? 1
            runtime.tick(n)
            writeLine("ok tick n=\(n) → tick=\(runtime.tickCounter)")
        case "click":
            guard args.count == 2, let x = Int(args[0]), let y = Int(args[1]) else {
                writeLine("! usage: click <x> <y>"); return
            }
            let outcome = runtime.leftClick(tileX: x, tileY: y)
            writeLine("ok click x=\(x) y=\(y) → \(Self.describe(outcome))")
        case "rclick":
            guard args.count == 2, let x = Int(args[0]), let y = Int(args[1]) else {
                writeLine("! usage: rclick <x> <y>"); return
            }
            let outcome = runtime.rightClick(tileX: x, tileY: y)
            writeLine("ok rclick x=\(x) y=\(y) → \(Self.describe(outcome))")
        case "sidebar":
            guard let row = args.first.flatMap({ Int($0) }) else {
                writeLine("! usage: sidebar <row>"); return
            }
            let outcome = runtime.sidebarClick(row: row)
            writeLine("ok sidebar row=\(row) → \(Self.describe(outcome))")
        case "yard":
            guard let idx = args.first.flatMap({ Int($0) }) else {
                writeLine("! usage: yard <idx>"); return
            }
            runtime.selectYard(index: idx)
            writeLine("ok yard selectedYard=\(runtime.buildController.selectedYardIndex ?? -1)")
        case "dump":
            guard let what = args.first else { writeLine("! usage: dump <what>"); return }
            dumpWhat(what, args: Array(args.dropFirst()))
        case "build":
            guard args.count == 3,
                  let type = UInt8(args[0]),
                  let x = Int(args[1]), let y = Int(args[2]) else {
                writeLine("! usage: build <type> <x> <y>  (stages placementType, then clicks)")
                return
            }
            runtime.buildController.placementType = type
            let outcome = runtime.leftClick(tileX: x, tileY: y)
            writeLine("ok build type=\(type) x=\(x) y=\(y) → \(Self.describe(outcome))")
        case "validity":
            guard args.count == 3,
                  let type = UInt8(args[0]),
                  let x = Int(args[1]), let y = Int(args[2]) else {
                writeLine("! usage: validity <type> <x> <y>"); return
            }
            let v = runtime.placementValidity(type: type, tileX: x, tileY: y)
            writeLine("ok validity type=\(type) x=\(x) y=\(y) → \(v.map(String.init) ?? "nil")")
        case "screenshot":
            // `screenshot <x> <y> <w> <h> <path>` — render the tile
            // region to a PNG. Pure ground-layer snapshot: reads each
            // cell's `groundTileID` from the runtime tileGrid and
            // composites the matching ICN tile. Unit / structure
            // markers are not drawn — the ground stamps carry
            // scenario + player structures, which is what we need
            // for regression tests on placement + palette.
            guard args.count == 5,
                  let x = Int(args[0]), let y = Int(args[1]),
                  let w = Int(args[2]), let h = Int(args[3])
            else {
                writeLine("! usage: screenshot <x> <y> <w> <h> <path>"); return
            }
            let path = args[4]
            do {
                try takeScreenshot(
                    originX: x, originY: y, widthTiles: w, heightTiles: h, path: path
                )
                writeLine("ok screenshot rect=(\(x),\(y),\(w),\(h)) path=\(path)")
            } catch {
                writeLine("! screenshot \(error)")
            }
        case "enqueue":
            guard let type = args.first.flatMap({ UInt8($0) }) else {
                writeLine("! usage: enqueue <type>"); return
            }
            guard let host = runtime.host,
                  let yardIdx = runtime.buildController.selectedYardIndex
            else { writeLine("! no yard selected"); return }
            var pool = host.structures
            let ok = Simulation.Structures.startConstruction(
                yardIndex: yardIdx, objectType: type, pool: &pool
            )
            host.structures = pool
            runtime.refreshBuildState()
            writeLine("ok enqueue type=\(type) yard=\(yardIdx) ok=\(ok)")
        default:
            writeLine("! unknown command: \(cmd). try 'help'.")
        }
    }

    // MARK: Dump

    private func dumpWhat(_ what: String, args: [String]) {
        switch what {
        case "units":
            guard let host = runtime.host else { writeLine("! no host"); return }
            for idx in host.units.findArray {
                let u = host.units.slots[idx]
                writeLine("unit idx=\(idx) type=\(u.type) house=\(u.houseID) action=\(u.actionID) pos=(\(u.positionX),\(u.positionY)) tile=(\(Int(u.positionX)/256),\(Int(u.positionY)/256)) hp=\(u.hitpoints) amount=\(u.amount) linkedID=\(u.linkedID) inT=\(u.inTransport) targetMove=\(String(format: "0x%04X", u.targetMove)) speed=\(u.speed)")
            }
            writeLine("ok dump units count=\(host.units.findArray.count)")
        case "structures":
            guard let host = runtime.host else { writeLine("! no host"); return }
            for idx in host.structures.findArray {
                let s = host.structures.slots[idx]
                let tx = Int(s.positionX) / 256
                let ty = Int(s.positionY) / 256
                writeLine("structure idx=\(idx) type=\(s.type) house=\(s.houseID) state=\(s.state) hp=\(s.hitpoints)/\(s.hitpointsMax) countDown=\(s.countDown) objectType=\(s.objectType) linkedID=\(s.linkedID) upgrade=\(s.upgradeLevel) tile=(\(tx),\(ty)) rally=\(String(format: "0x%04X", s.rallyPointPacked))")
            }
            writeLine("ok dump structures count=\(host.structures.findArray.count)")
        case "houses":
            guard let host = runtime.host else { writeLine("! no host"); return }
            for idx in 0..<host.houses.slots.count {
                let h = host.houses.slots[idx]
                guard h.isUsed else { continue }
                writeLine("house idx=\(idx) credits=\(h.credits) storage=\(h.creditsStorage) quota=\(h.creditsQuota)")
            }
            writeLine("ok dump houses")
        case "tile":
            guard args.count == 2, let x = Int(args[0]), let y = Int(args[1]) else {
                writeLine("! usage: dump tile <x> <y>"); return
            }
            dumpTile(x: x, y: y)
        case "build":
            dumpBuildState()
        case "spice":
            dumpSpice()
        case "scene":
            writeLine("scene tick=\(runtime.tickCounter) selectedYard=\(runtime.buildController.selectedYardIndex ?? -1) placement=\(runtime.buildController.placementType.map(String.init) ?? "nil") yardKind=\(runtime.currentYardKind)")
            writeLine("ok dump scene")
        case "selection":
            let unitIdx = runtime.commandController.selectedUnitIndex
            let friendly = runtime.commandController.isFriendlySelection
            let structIdx = runtime.selectedStructureIndex
            let yardIdx = runtime.buildController.selectedYardIndex
            writeLine("selection unit=\(unitIdx.map(String.init) ?? "nil") unitFriendly=\(friendly) structure=\(structIdx.map(String.init) ?? "nil") yard=\(yardIdx.map(String.init) ?? "nil")")
            writeLine("ok dump selection")
        default:
            writeLine("! unknown dump target: \(what)")
        }
    }

    private func dumpTile(x: Int, y: Int) {
        guard let host = runtime.host else { writeLine("! no host"); return }
        guard (0..<64).contains(x), (0..<64).contains(y) else {
            writeLine("! tile off-map"); return
        }
        let tileIdx = y * 64 + x
        guard tileIdx < runtime.tileGrid.count else {
            writeLine("! tile grid too small"); return
        }
        let cell = runtime.tileGrid[tileIdx]
        let resolver = runtime.assets.tileResolver
        let landscape = resolver.landscapeType(
            groundTileID: cell.groundTileID,
            overlayTileID: cell.overlayTileID,
            hasStructure: cell.hasStructure
        )
        var structureHit: String = "none"
        for idx in host.structures.findArray {
            let s = host.structures.slots[idx]
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let footprint = Simulation.Structures.footprintTiles(
                type: s.type, anchorX: ax, anchorY: ay
            )
            if footprint.contains(where: { $0.0 == x && $0.1 == y }) {
                structureHit = "idx=\(idx) type=\(s.type) house=\(s.houseID)"
                break
            }
        }
        var unitHit: String = "none"
        for idx in host.units.findArray {
            let u = host.units.slots[idx]
            let ux = Int(u.positionX) / 256
            let uy = Int(u.positionY) / 256
            if ux == x && uy == y {
                unitHit = "idx=\(idx) type=\(u.type) house=\(u.houseID)"
                break
            }
        }
        let spice: String
        if let m = host.spiceMap {
            spice = "\(m[x, y])"
        } else {
            spice = "nil"
        }
        writeLine("tile x=\(x) y=\(y) landscape=\(landscape) groundID=\(cell.groundTileID) overlayID=\(cell.overlayTileID) houseID=\(cell.houseID) structure=\(structureHit) unit=\(unitHit) spice=\(spice)")
        writeLine("ok dump tile")
    }

    private func dumpBuildState() {
        let bc = runtime.buildController
        var s = "build selectedYard=\(bc.selectedYardIndex ?? -1) placement=\(bc.placementType.map(String.init) ?? "nil") yardState=\(bc.yardState.map { "\($0)" } ?? "nil") queued=\(bc.queuedType.map(String.init) ?? "nil") countDown=\(bc.countDown.map(String.init) ?? "nil") buildTime=\(bc.buildTime.map(String.init) ?? "nil") available=\(bc.availableTypes)"
        if let p = bc.progress { s += " progress=\(String(format: "%.2f", p))" }
        writeLine(s)
        writeLine("ok dump build")
    }

    private func dumpSpice() {
        guard let host = runtime.host, let map = host.spiceMap else {
            writeLine("! no spiceMap"); return
        }
        let thick = map.cells.filter { $0 == .thick }.count
        let thin = map.cells.filter { $0 == .thin }.count
        let notSand = map.cells.filter { $0 == .notSand }.count
        let bare = map.cells.filter { $0 == .bare }.count
        writeLine("spice thick=\(thick) thin=\(thin) bare=\(bare) notSand=\(notSand)")
        var samples: [String] = []
        for (i, lvl) in map.cells.enumerated() where lvl == .thick || lvl == .thin {
            samples.append("(\(i % 64),\(i / 64)):\(lvl)")
            if samples.count >= 10 { break }
        }
        if !samples.isEmpty { writeLine("spice-samples \(samples.joined(separator: " "))") }
        writeLine("ok dump spice")
    }

    // MARK: Utilities

    private func writeLine(_ s: String) {
        out.write(Data((s + "\n").utf8))
    }

    /// Renders the live tile grid + structure outlines + units +
    /// selection halo for a tile rectangle to a PNG on disk via the
    /// shared `ScreenshotRenderer`. 16 pixels per tile. Short-circuits
    /// when no scenario is loaded.
    private func takeScreenshot(
        originX: Int, originY: Int,
        widthTiles: Int, heightTiles: Int, path: String
    ) throws {
        guard runtime.host != nil else { throw ScreenshotError.noScenarioLoaded }
        guard widthTiles > 0, heightTiles > 0 else {
            throw ScreenshotError.invalidRect
        }
        let renderer = ScreenshotRenderer(loader: runtime.assets)
        let data = try renderer.renderPNGData(
            runtime: runtime,
            originTileX: originX, originTileY: originY,
            widthTiles: widthTiles, heightTiles: heightTiles
        )
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
        Log.info(
            "screenshot rect=(\(originX),\(originY),\(widthTiles),\(heightTiles)) → \(path)",
            tracer: .label("screenshot")
        )
    }

    enum ScreenshotError: Error, CustomStringConvertible {
        case noScenarioLoaded
        case invalidRect
        case contextCreationFailed
        var description: String {
            switch self {
            case .noScenarioLoaded: return "no scenario loaded (use `load <name>` first)"
            case .invalidRect: return "width and height must be positive"
            case .contextCreationFailed: return "CGContext creation / readback failed"
            }
        }
    }

    private static func describe(_ o: ScenarioRuntime.ClickOutcome) -> String {
        switch o {
        case .none: return "none"
        case .unitSelected(let i): return "unitSelected(\(i))"
        case .unitDeselected: return "unitDeselected"
        case .orderMove(let u, let x, let y, let ok): return "orderMove(unit=\(u) tile=(\(x),\(y)) ok=\(ok))"
        case .orderAttack(let a, let t, let ok): return "orderAttack(attacker=\(a) target=\(t) ok=\(ok))"
        case .orderAttackStructure(let a, let s, let ok): return "orderAttackStructure(attacker=\(a) target=s\(s) ok=\(ok))"
        case .yardSelected(let i): return "yardSelected(\(i))"
        case .structureSelected(let i): return "structureSelected(\(i))"
        case .placementStarted(let t): return "placementStarted(type=\(t))"
        case .placementCommitted(let t, let s, let x, let y, let d): return "placementCommitted(type=\(t) slot=\(s) tile=(\(x),\(y)) degraded=\(d))"
        case .placementRejected(let t, let x, let y): return "placementRejected(type=\(t) tile=(\(x),\(y)))"
        case .placementPoolFull(let t, let x, let y): return "placementPoolFull(type=\(t) tile=(\(x),\(y)))"
        case .constructionEnqueued(let y, let t, let ok): return "constructionEnqueued(yard=\(y) type=\(t) ok=\(ok))"
        case .constructionCancelled(let y, let t): return "constructionCancelled(yard=\(y) type=\(t))"
        case .factorySpawned(let y, let u, let t): return "factorySpawned(yard=\(y) unit=\(u) type=\(t))"
        case .factoryPoolFull(let y, let t): return "factoryPoolFull(yard=\(y) type=\(t))"
        case .rallySet(let y, let x, let ty): return "rallySet(yard=\(y) tile=(\(x),\(ty)))"
        case .rallyCleared(let y): return "rallyCleared(yard=\(y))"
        }
    }

    private static let helpText: [String] = [
        "# commands (inputs on stdin, one per line):",
        "#   load <scenario>         e.g. load SCENA001",
        "#   tick [N]                advance N scheduler ticks (default 1)",
        "#   click <x> <y>           left-click at map tile",
        "#   rclick <x> <y>          right-click at map tile",
        "#   sidebar <row>           click sidebar row",
        "#   yard <idx>              force-select a yard",
        "#   enqueue <type>          start construction of <type> on selected yard",
        "#   build <type> <x> <y>    force placementType then click to place",
        "#   validity <type> <x> <y> read placement validity without mutating",
        "#   dump units              list live units",
        "#   dump structures         list live structures",
        "#   dump houses             list house credits",
        "#   dump tile <x> <y>       landscape + structure + unit + spice at tile",
        "#   dump build              current build-panel state",
        "#   dump spice              SpiceMap summary + samples",
        "#   dump scene              tickCounter, selectedYard, placementType",
        "#   screenshot x y w h path  render tile rect to PNG (16 px / tile)",
        "#   quit                    exit",
    ]
}

MainActor.assumeIsolated {
    let h = Harness()
    h.run()
}
