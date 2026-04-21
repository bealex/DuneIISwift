import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Emc")
struct EmcTests {
    // MARK: Instruction decode (synthetic, no chunk container)

    @Test("0x8007 is a 13-bit JUMP with parameter 7")
    func jumpHighBit() throws {
        let code: [UInt16] = [0x8007]
        let program = try Formats.Emc.Program.decodeCode(code)
        #expect(program.instructions.count == 1)
        let i = program.instructions[0]
        #expect(i.opcode == .jump)
        #expect(i.parameter == 7)
        #expect(i.wordSize == 1)
    }

    @Test("0x43C0 encodes opcode 3 (PUSH) with sign-extended parameter -64")
    func signExtendedParameter() throws {
        let code: [UInt16] = [0x43C0]
        let program = try Formats.Emc.Program.decodeCode(code)
        let i = program.instructions[0]
        #expect(i.opcode == .push)
        #expect(i.parameter == -64)
    }

    @Test("0x2700 followed by 0x1234 is a 2-word PUSH_PARAMETER")
    func twoWordParameter() throws {
        let code: [UInt16] = [0x2700, 0x1234]
        let program = try Formats.Emc.Program.decodeCode(code)
        #expect(program.instructions.count == 1)
        let i = program.instructions[0]
        #expect(i.opcode == .pushParameter)
        #expect(i.parameter == 0x1234)
        #expect(i.wordSize == 2)
    }

    @Test("opcode with all three parameter bits clear has parameter 0")
    func zeroParameter() throws {
        let code: [UInt16] = [0x1200] // opcode = 0x12 & 0x1F = 18 = RETURN, param bits clear
        let program = try Formats.Emc.Program.decodeCode(code)
        #expect(program.instructions[0].opcode == .ret)
        #expect(program.instructions[0].parameter == 0)
    }

    @Test("wordIndexToInsn maps second word of a 2-word instruction to the parent index")
    func wordToInsnMapping() throws {
        let code: [UInt16] = [0x2700, 0x1234, 0x0100]
        let program = try Formats.Emc.Program.decodeCode(code)
        // Instructions: [PUSH_PARAMETER (2 words), SETRETURNVALUE (1 word)]
        #expect(program.instructions.count == 2)
        #expect(program.wordIndexToInsn[0] == 0)
        #expect(program.wordIndexToInsn[1] == 0) // middle of first
        #expect(program.wordIndexToInsn[2] == 1)
    }

    @Test("unknown opcode is rejected")
    func unknownOpcode() {
        // Opcode = (0x1F00 >> 8) & 0x1F = 0x1F = 31 → undefined.
        let code: [UInt16] = [0x1F00]
        #expect(throws: Formats.Emc.Program.DecodeError.self) {
            _ = try Formats.Emc.Program.decodeCode(code)
        }
    }

    // MARK: Full container

    @Test("synthetic FORM with all three chunks round-trips")
    func syntheticForm() throws {
        let textChunk = makeTextChunk(strings: ["hello", "world"])
        let ordrChunk = makeOrdrChunk(entries: [0, 5, 12])
        let dataChunk = makeDataChunk(words: [0x8007, 0x1200, 0x43C0])
        let form = makeEmcForm(chunks: [
            ("TEXT", textChunk),
            ("ORDR", ordrChunk),
            ("DATA", dataChunk)
        ])

        let program = try Formats.Emc.Program.decode(form)
        #expect(program.texts == ["hello", "world"])
        #expect(program.entryPoints == [0, 5, 12])
        #expect(program.instructions.count == 3)
    }

    @Test("missing DATA chunk raises an error")
    func missingData() {
        let form = makeEmcForm(chunks: [("TEXT", makeTextChunk(strings: [])),
                                         ("ORDR", makeOrdrChunk(entries: [0]))])
        #expect(throws: Formats.Emc.Program.DecodeError.self) {
            _ = try Formats.Emc.Program.decode(form)
        }
    }

    @Test("real UNIT.EMC decodes into a plausible program")
    func realUnitEmc() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "UNIT.EMC") else { return }
        let program = try Formats.Emc.Program.decode(body)
        #expect(!program.entryPoints.isEmpty)
        #expect(!program.instructions.isEmpty)
        // All opcodes must be within the 19 defined values.
        for insn in program.instructions {
            #expect((0...18).contains(insn.opcode.rawValue))
        }
    }
}

// MARK: - Chunk builders

private func makeTextChunk(strings: [String]) -> Data {
    let offsetTable = UInt16(strings.count * 2)
    var body = Data()
    var pool = Data()
    var current = offsetTable
    for s in strings {
        body.append(uint16BE: current)
        var bytes = Array(s.utf8)
        bytes.append(0)
        pool.append(contentsOf: bytes)
        current += UInt16(bytes.count)
    }
    body.append(pool)
    return body
}

private func makeOrdrChunk(entries: [UInt16]) -> Data {
    var body = Data()
    for e in entries { body.append(uint16BE: e) }
    return body
}

private func makeDataChunk(words: [UInt16]) -> Data {
    var body = Data()
    for w in words { body.append(uint16BE: w) }
    return body
}

private func makeEmcForm(chunks: [(String, Data)]) -> Data {
    var body = Data()
    body.append(contentsOf: Array("EMC ".utf8))
    for (tag, chunk) in chunks {
        body.append(contentsOf: Array(tag.utf8))
        body.append(uint32BE: UInt32(chunk.count))
        body.append(chunk)
        if chunk.count % 2 != 0 { body.append(0) }
    }
    var out = Data("FORM".utf8)
    out.append(uint32BE: UInt32(body.count))
    out.append(body)
    return out
}

private extension Data {
    mutating func append(uint16BE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func append(uint32BE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
