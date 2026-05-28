import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Emc")
struct EmcTests {
    // One type whose script is: FUNCTION 0x08 (inline 8-bit operand), then RETURN.
    static func synthetic() -> Data {
        IffBuilder.form("EMC2", [
            IffBuilder.chunk("ORDR", [ 0x00, 0x00 ]),               // type 0 entry @ word 0
            IffBuilder.chunk("DATA", [ 0x4E, 0x08, 0x12, 0x00 ]),   // FUNCTION 8 (0x4E08), RETURN (0x1200)
        ])
    }

    @Test("parses ORDR/DATA and disassembles opcodes + function names")
    func disassemble() throws {
        let program = try Emc.Program(EmcTests.synthetic())
        #expect(program.offsets == [ 0 ])
        #expect(program.data == [ 0x4E08, 0x1200 ])

        let instructions = Emc.disassemble(program, typeIndex: 0, kind: .unit)
        #expect(instructions.count == 2)
        #expect(instructions[0] == Emc.Instruction(
            address: 0, opcode: 14, name: "Function", operand: 8, functionName: "Unit_Fire"
        ))
        #expect(instructions[1] == Emc.Instruction(
            address: 1, opcode: 18, name: "Return", operand: nil, functionName: nil
        ))
    }

    @Test("missing DATA/ORDR throws")
    func missing() {
        #expect(throws: Emc.DecodeError.missingChunk) {
            _ = try Emc.Program(IffBuilder.form("EMC2", []))
        }
    }

    @Test("real install UNIT.EMC disassembles")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: "UNIT.EMC") else { return }

        let program = try Emc.Program(bytes)
        #expect(!program.offsets.isEmpty)
        #expect(!program.data.isEmpty)
        let instructions = Emc.disassemble(program, typeIndex: 0, kind: .unit)
        #expect(!instructions.isEmpty)
    }
}
