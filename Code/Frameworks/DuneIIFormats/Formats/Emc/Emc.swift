import Foundation

/// Parser and disassembler for EMC scripts (`UNIT.EMC`, `BUILD.EMC`, `TEAM.EMC`). The bytecode is
/// kept as data and reproduced as readable listings so the per-type state machines can be transcribed
/// exactly (we do not execute it). Ported from `Script_LoadFromFile` (OpenDUNE `src/script/script.c:650`)
/// and the instruction decode in `Script_Run` (`src/script/script.c:323`).
///
/// Container: IFF/FORM with `TEXT` (string table), `ORDR` (per-type entry offsets, big-endian uint16
/// word offsets into DATA), and `DATA` (big-endian uint16 bytecode words). See `Documentation/Formats/Emc.md`.
public enum Emc {
    public enum DecodeError: Error, Equatable {
        case missingChunk
    }

    public enum ObjectKind {
        case unit
        case structure
        case team
    }

    public struct Program {
        public let text: [UInt8]
        public let offsets: [Int]    // ORDR: per-type entry, as a word index into `data`
        public let data: [UInt16]    // DATA: bytecode words (decoded from big-endian)

        public init(_ data: Data) throws {
            let reader = try Iff.Reader(data)
            guard let ordr = reader.chunk("ORDR"), let code = reader.chunk("DATA") else {
                throw DecodeError.missingChunk
            }

            let ordrBytes = [UInt8](ordr)
            var offsets: [Int] = []
            var o = 0
            while o + 2 <= ordrBytes.count {
                offsets.append(ordrBytes.u16BE(at: o))
                o += 2
            }

            let codeBytes = [UInt8](code)
            var words: [UInt16] = []
            var c = 0
            while c + 2 <= codeBytes.count {
                words.append(UInt16(codeBytes.u16BE(at: c)))
                c += 2
            }

            self.text = [UInt8](reader.chunk("TEXT") ?? Data())
            self.offsets = offsets
            self.data = words
        }
    }

    public struct Instruction: Equatable {
        public let address: Int       // word index into DATA
        public let opcode: Int
        public let name: String
        public let operand: Int?
        public let functionName: String?   // set when the opcode is FUNCTION (14)
    }

    /// Disassemble the script for one object type, from its ORDR entry to the next entry's address.
    public static func disassemble(_ program: Program, typeIndex: Int, kind: ObjectKind) -> [Instruction] {
        guard typeIndex >= 0, typeIndex < program.offsets.count else { return [] }

        let start = program.offsets[typeIndex]
        let end = program.offsets.filter { $0 > start }.min() ?? program.data.count
        return disassemble(program, from: start, to: end, kind: kind)
    }

    /// Disassemble a raw address range `[from, to)`. Backs the per-type view (via the ORDR offsets) and the
    /// whole-program / shared-subroutine view: the common routines below the lowest type entry, reached only
    /// via `Jump`, that the per-type view never reaches (e.g. a structure's death/turret/refine branches).
    public static func disassemble(_ program: Program, from: Int, to: Int, kind: ObjectKind) -> [Instruction] {
        var instructions: [Instruction] = []
        var address = max(from, 0)
        let end = min(to, program.data.count)
        while address < end {
            let instructionAddress = address
            let word = Int(program.data[address])
            address += 1

            let opcode: Int
            var operand: Int?
            if word & 0x8000 != 0 {
                opcode = 0   // forced JUMP
                operand = word & 0x7FFF
            } else {
                opcode = (word >> 8) & 0x1F
                if word & 0x4000 != 0 {
                    let raw = word & 0xFF
                    operand = raw < 0x80 ? raw : raw - 0x100   // sign-extended 8-bit
                } else if word & 0x2000 != 0 {
                    if address < program.data.count {
                        operand = Int(program.data[address])
                        address += 1
                    }
                }
            }

            let name = opcode < commandNames.count ? commandNames[opcode] : "Unknown"
            var functionName: String?
            if opcode == 14, let operand {
                functionName = Emc.functionName(kind, index: operand & 0xFF)
            }
            instructions.append(Instruction(
                address: instructionAddress,
                opcode: opcode,
                name: name,
                operand: operand,
                functionName: functionName
            ))
        }
        return instructions
    }

    static let commandNames = [
        "Jump", "SetReturnValue", "PushReturnOrLocation", "Push", "Push2", "PushVariable",
        "PushLocalVariable", "PushParameter", "PopReturnOrLocation", "PopVariable", "PopLocalVariable",
        "PopParameter", "StackRewind", "StackForward", "Function", "JumpNotEqual", "Unary", "Binary", "Return",
    ]

    static func functionName(_ kind: ObjectKind, index: Int) -> String {
        let table: [String]
        switch kind {
            case .unit: table = unitFunctions
            case .structure: table = structureFunctions
            case .team: table = teamFunctions
        }
        return index >= 0 && index < table.count ? table[index] : "NoOperation"
    }

    static let unitFunctions = [
        "Unit_GetInfo", "Unit_SetAction", "General_DisplayText", "General_GetDistanceToTile",
        "Unit_StartAnimation", "Unit_SetDestination", "Unit_GetOrientation", "Unit_SetOrientation",
        "Unit_Fire", "Unit_MCVDeploy", "Unit_SetActionDefault", "Unit_Blink", "Unit_CalculateRoute",
        "General_IsEnemy", "Unit_ExplosionSingle", "Unit_Die", "General_Delay", "General_IsFriendly",
        "Unit_ExplosionMultiple", "Unit_SetSprite", "Unit_TransportDeliver", "NoOperation",
        "Unit_MoveToTarget", "General_RandomRange", "General_FindIdle", "Unit_SetDestinationDirect",
        "Unit_Stop", "Unit_SetSpeed", "Unit_FindBestTarget", "Unit_GetTargetPriority",
        "Unit_MoveToStructure", "Unit_IsInTransport", "Unit_GetAmount", "Unit_RandomSoldier",
        "Unit_Pickup", "Unit_CallUnitByType", "Unit_Unknown2552", "Unit_FindStructure",
        "General_VoicePlay", "Unit_DisplayDestroyedText", "Unit_RemoveFog", "General_SearchSpice",
        "Unit_Harvest", "NoOperation", "General_GetLinkedUnitType", "General_GetIndexType",
        "General_DecodeIndex", "Unit_IsValidDestination", "Unit_GetRandomTile", "Unit_IdleAction",
        "General_UnitCount", "Unit_GoToClosestStructure", "NoOperation", "NoOperation",
        "Unit_Sandworm_GetBestTarget", "Unit_Unknown2BD5", "General_GetOrientation", "NoOperation",
        "Unit_SetTarget", "General_Unknown0288", "General_DelayRandom", "Unit_Rotate",
        "General_GetDistanceToObject", "NoOperation",
    ]

    static let structureFunctions = [
        "General_Delay", "NoOperation", "Structure_Unknown0A81", "Structure_FindUnitByType",
        "Structure_SetState", "General_DisplayText", "Structure_Unknown11B9", "Structure_Unknown0C5A",
        "Structure_FindTargetUnit", "Structure_RotateTurret", "Structure_GetDirection", "Structure_Fire",
        "NoOperation", "Structure_GetState", "Structure_VoicePlay", "Structure_RemoveFogAroundTile",
        "NoOperation", "NoOperation", "NoOperation", "NoOperation", "NoOperation", "Structure_RefineSpice",
        "Structure_Explode", "Structure_Destroy", "NoOperation",
    ]

    static let teamFunctions = [
        "General_Delay", "Team_DisplayText", "Team_GetMembers", "Team_AddClosestUnit",
        "Team_GetAverageDistance", "Team_Unknown0543", "Team_FindBestTarget", "Team_Unknown0788",
        "Team_Load", "Team_Load2", "General_DelayRandom", "General_DisplayModalMessage",
        "Team_GetVariable6", "Team_GetTarget", "NoOperation",
    ]
}
