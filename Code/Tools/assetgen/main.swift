import DuneIIFormats
import Foundation

// Dune II asset tool. Currently provides `emc-disasm`, which renders an EMC script to a readable
// opcode listing so the per-type state machines can be transcribed exactly (Phase 3). Full asset
// regeneration into Resources/ (PNG/WAV writers) is a later step; Resources/ is committed today.

func usage() {
    print("usage:")
    print("  assetgen emc-disasm <file.EMC> [unit|structure|team]")
}

func objectKind(path: String, override: String?) -> Emc.ObjectKind {
    if let override = override?.lowercased() {
        if override.hasPrefix("s") || override.hasPrefix("b") { return .structure }
        if override.hasPrefix("t") { return .team }
        return .unit
    }

    let name = (path as NSString).lastPathComponent.uppercased()
    if name.contains("BUILD") { return .structure }
    if name.contains("TEAM") { return .team }
    return .unit
}

func runEmcDisasm(_ arguments: [String]) {
    guard let path = arguments.first else { usage(); exit(1) }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("assetgen: cannot read \(path)")
        exit(1)
    }

    let kind = objectKind(path: path, override: arguments.count >= 2 ? arguments[1] : nil)
    do {
        let program = try Emc.Program(data)
        for typeIndex in program.offsets.indices {
            let instructions = Emc.disassemble(program, typeIndex: typeIndex, kind: kind)
            guard !instructions.isEmpty else { continue }

            print("; ---- type \(typeIndex) (entry @\(program.offsets[typeIndex])) ----")
            for instruction in instructions {
                var line = String(format: "%5d:  %@", instruction.address, instruction.name)
                if let operand = instruction.operand { line += " \(operand)" }
                if let functionName = instruction.functionName { line += "  ; \(functionName)" }
                print(line)
            }
        }
    } catch {
        print("assetgen: emc-disasm failed: \(error)")
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("assetgen — Dune II asset tool")
    usage()
    exit(0)
}

switch command {
    case "emc-disasm":
        runEmcDisasm(Array(arguments.dropFirst()))
    default:
        print("assetgen: unknown command '\(command)'")
        usage()
        exit(1)
}
