import Foundation
import DuneIICore
import AssetExport

struct StdoutLogger: ExtractLogger {
    var verbose: Bool
    func info(_ s: String) { print(s) }
    func detail(_ s: @autoclosure () -> String) { if verbose { print(s()) } }
    func warn(_ s: String) { FileHandle.standardError.write(Data("warn: \(s)\n".utf8)) }
}

struct Options {
    var installDir: URL
    var outputDir: URL
    var verbose = false
    var copyOriginalPaks = false
}

enum CLI {
    static func parse(_ args: [String]) -> Options {
        let repoRoot = Self.locateRepoRoot()
        var opts = Options(
            installDir: repoRoot.appendingPathComponent("Repositories/patched_107_unofficial"),
            outputDir: repoRoot.appendingPathComponent("Resources")
        )
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--install":
                i += 1
                opts.installDir = URL(fileURLWithPath: args[i])
            case "--output":
                i += 1
                opts.outputDir = URL(fileURLWithPath: args[i])
            case "-v", "--verbose":
                opts.verbose = true
            case "--copy-originals":
                opts.copyOriginalPaks = true
            case "-h", "--help":
                print("""
                Usage: assetgen [--install DIR] [--output DIR] [-v] [--copy-originals]

                Decodes every PAK in the install directory and writes the results
                under the output directory as a curated Resources/ tree.

                Defaults:
                  --install \(opts.installDir.path)
                  --output  \(opts.outputDir.path)
                """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
                exit(64)
            }
            i += 1
        }
        return opts
    }

    private static func locateRepoRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("Documentation/Plans/01.Initial.md")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

/// Maps a PAK entry's extension to the right extractor. Pure routing logic —
/// tested separately. Any unroutable entry lands under `Unknown/<pak>/`.
enum Router {
    static func route(
        pakName: String,
        entry: Formats.Pak.Entry,
        body: Data,
        ctx: ExtractContext
    ) {
        let ext = (entry.name as NSString).pathExtension.uppercased()
        let stem = (entry.name as NSString).deletingPathExtension
        let logger = ctx.logger
        do {
            switch ext {
            case "PAL":
                try Extractors.extractPalette(name: stem, data: body, ctx: ctx)
                logger.detail("  pal   \(entry.name)")
            case "CPS":
                try Extractors.extractCps(name: stem, data: body, ctx: ctx)
                logger.detail("  cps   \(entry.name)")
            case "SHP":
                try Extractors.extractShp(name: stem, data: body, ctx: ctx)
                logger.detail("  shp   \(entry.name)")
            case "WSA":
                try Extractors.extractWsa(name: stem, data: body, ctx: ctx)
                logger.detail("  wsa   \(entry.name)")
            case "ICN":
                try Extractors.extractIcn(name: stem, data: body, ctx: ctx)
                logger.detail("  icn   \(entry.name)")
            case "FNT":
                try Extractors.extractFnt(name: stem, data: body, ctx: ctx)
                logger.detail("  fnt   \(entry.name)")
            case "VOC":
                try Extractors.extractVoc(name: stem, data: body, ctx: ctx)
                logger.detail("  voc   \(entry.name)")
            case "XMI":
                try Extractors.extractXmi(name: stem, data: body, ctx: ctx)
                logger.detail("  xmi   \(entry.name)")
            case "C55", "ADL", "PCS", "TAN":
                // Other-synth music banks: raw passthrough until we have an
                // OPL emulator / MT-32 / PC-speaker / Tandy synth path.
                try Extractors.passthrough(name: entry.name, data: body, category: "Audio/Music", ctx: ctx)
                logger.detail("  mus   \(entry.name)  (passthrough)")
            case "EMC":
                try Extractors.extractEmc(name: stem, data: body, ctx: ctx)
                logger.detail("  emc   \(entry.name)")
            case "INI":
                try Extractors.passthrough(name: entry.name, data: body, category: "Scenarios", ctx: ctx)
                logger.detail("  ini   \(entry.name)  (passthrough)")
            case "MAP":
                try Extractors.passthrough(name: entry.name, data: body, category: "Tiles/Maps", ctx: ctx)
                logger.detail("  map   \(entry.name)  (passthrough)")
            case "TBL":
                try Extractors.passthrough(name: entry.name, data: body, category: "Tables", ctx: ctx)
                logger.detail("  tbl   \(entry.name)  (passthrough)")
            case "ENG", "GER", "FRE", "ITA", "SPA":
                try Extractors.passthrough(name: entry.name, data: body, category: "Strings", ctx: ctx)
                logger.detail("  str   \(entry.name)  (passthrough)")
            case "DRV", "ADV":
                try Extractors.passthrough(name: entry.name, data: body, category: "Audio/Drivers", ctx: ctx)
                logger.detail("  drv   \(entry.name)  (passthrough)")
            default:
                try Extractors.passthrough(name: entry.name, data: body, category: "Unknown/\(pakName)", ctx: ctx)
                logger.warn("unrouted: \(pakName)/\(entry.name)")
            }
        } catch {
            logger.warn("\(pakName)/\(entry.name): \(error)")
        }
    }
}

// MARK: - Main

let opts = CLI.parse(CommandLine.arguments)
let logger = StdoutLogger(verbose: opts.verbose)
let fm = FileManager.default

guard fm.fileExists(atPath: opts.installDir.path) else {
    logger.warn("install dir not found: \(opts.installDir.path)")
    exit(1)
}

for folder in ["Palettes", "Screens", "Sprites", "Animations", "Tiles", "Fonts",
               "Audio", "Scripts", "Scenarios", "Tables", "Strings", "Unknown", "Original"] {
    let url = opts.outputDir.appendingPathComponent(folder)
    try? fm.removeItem(at: url)
}

let paks: [URL]
do {
    let items = try fm.contentsOfDirectory(at: opts.installDir, includingPropertiesForKeys: nil)
    paks = items.filter { $0.pathExtension.uppercased() == "PAK" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    logger.warn("failed to list install dir: \(error)")
    exit(1)
}

if paks.isEmpty {
    logger.warn("no PAK files in \(opts.installDir.path)")
    exit(1)
}

logger.info("scanning \(paks.count) PAK files under \(opts.installDir.path)")

var fallbackPalette: Formats.Palette?
for pak in paks {
    guard let archive = try? Formats.Pak.Archive(contentsOf: pak) else { continue }
    if let body = archive.body(named: "IBM.PAL"),
       let palette = try? Formats.Palette(data: body) {
        fallbackPalette = palette
        logger.info("using IBM.PAL from \(pak.lastPathComponent) as default palette")
        break
    }
}
if fallbackPalette == nil {
    logger.warn("IBM.PAL not found — sprites/tiles will be skipped")
}

let ctx = ExtractContext(outputRoot: opts.outputDir, fallbackPalette: fallbackPalette, logger: logger)

if opts.copyOriginalPaks {
    let originalDir = ctx.dir("Original")
    for pak in paks {
        try? fm.copyItem(at: pak, to: originalDir.appendingPathComponent(pak.lastPathComponent))
    }
    logger.info("copied \(paks.count) PAKs to Original/")
}

var totalEntries = 0
for pak in paks {
    let archive: Formats.Pak.Archive
    do {
        archive = try Formats.Pak.Archive(contentsOf: pak)
    } catch {
        logger.warn("\(pak.lastPathComponent): failed to open — \(error)")
        continue
    }
    logger.info("\(pak.lastPathComponent) — \(archive.entries.count) entries")
    totalEntries += archive.entries.count
    for entry in archive.entries {
        let body = archive.body(for: entry)
        Router.route(pakName: pak.deletingPathExtension().lastPathComponent,
                     entry: entry, body: body, ctx: ctx)
    }
}

logger.info("done — \(totalEntries) entries processed, output in \(opts.outputDir.path)")
