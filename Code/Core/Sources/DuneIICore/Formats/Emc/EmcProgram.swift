import Foundation

extension Formats {
    public enum Emc {
        /// Opcode table — exactly matches OpenDUNE `SCRIPT_*` enum.
        public enum Opcode: UInt8, Sendable, CaseIterable {
            case jump                  = 0
            case setReturnValue        = 1
            case pushReturnOrLocation  = 2
            case push                  = 3
            case push2                 = 4
            case pushVariable          = 5
            case pushLocalVariable     = 6
            case pushParameter         = 7
            case popReturnOrLocation   = 8
            case popVariable           = 9
            case popLocalVariable      = 10
            case popParameter          = 11
            case stackRewind           = 12
            case stackForward          = 13
            case function              = 14
            case jumpNotEqual          = 15
            case unary                 = 16
            case binary                = 17
            case ret                   = 18
        }

        public struct Instruction: Sendable, Equatable {
            public let opcode: Opcode
            public let parameter: Int
            public let rawWord: UInt16
            /// 1 for single-word instructions, 2 when the `0x2000` flag is set
            /// and a second word supplies the parameter.
            public let wordSize: Int
        }

        public struct Program: Sendable {
            public let texts: [String]
            public let entryPoints: [UInt16]
            public let code: [UInt16]
            public let instructions: [Instruction]
            /// For each word in `code`, the index of the instruction that
            /// owns that word (the parent for a 2-word instruction). This
            /// lets future VM callers follow a jump to a mid-stream word
            /// and find the instruction that starts at or before it.
            public let wordIndexToInsn: [Int]

            public enum DecodeError: Error, Equatable, Sendable {
                case notFormForm
                case missingChunk(String)
                case truncated
                case unknownOpcode(value: UInt8, atWord: Int)
            }

            /// Canonical zero-instruction program. Useful for wiring the
            /// `Scripting.VM` when no script payload is available — the VM
            /// halts on first step.
            public static var empty: Program {
                // `decodeCode([])` cannot throw for an empty slice.
                return (try? decodeCode([])) ?? Program(
                    texts: [], entryPoints: [], code: [],
                    instructions: [], wordIndexToInsn: []
                )
            }

            public static func decode(_ data: Data) throws -> Program {
                guard data.count >= 12 else { throw DecodeError.notFormForm }
                let base = data.startIndex
                guard readFourCC(data, at: base) == "FORM" else { throw DecodeError.notFormForm }
                let chunks = try readChunks(data)

                guard let dataChunk = chunks["DATA"] else { throw DecodeError.missingChunk("DATA") }
                let code = chunkAsBEWords(dataChunk)

                let entryPoints = chunks["ORDR"].map(chunkAsBEWords) ?? []
                let texts = try chunks["TEXT"].map(parseTextChunk) ?? []

                return try decodeFromCode(code, texts: texts, entryPoints: entryPoints)
            }

            /// Decodes an opcode stream directly. Used by tests that don't
            /// care about the IFF container.
            public static func decodeCode(_ code: [UInt16]) throws -> Program {
                return try decodeFromCode(code, texts: [], entryPoints: [])
            }

            private static func decodeFromCode(
                _ code: [UInt16],
                texts: [String],
                entryPoints: [UInt16]
            ) throws -> Program {
                var insns: [Instruction] = []
                var wordToInsn = [Int](repeating: -1, count: code.count)
                var i = 0
                while i < code.count {
                    let word = code[i]
                    let opcodeRaw: UInt8
                    let parameter: Int
                    let wordSize: Int

                    if word & 0x8000 != 0 {
                        opcodeRaw = 0 // JUMP
                        parameter = Int(word & 0x7FFF)
                        wordSize = 1
                    } else {
                        opcodeRaw = UInt8((word >> 8) & 0x1F)
                        if word & 0x4000 != 0 {
                            let low = Int8(bitPattern: UInt8(word & 0xFF))
                            parameter = Int(low) // sign-extended
                            wordSize = 1
                        } else if word & 0x2000 != 0 {
                            guard i + 1 < code.count else { throw DecodeError.truncated }
                            parameter = Int(code[i + 1])
                            wordSize = 2
                        } else {
                            parameter = 0
                            wordSize = 1
                        }
                    }

                    guard let opcode = Opcode(rawValue: opcodeRaw) else {
                        throw DecodeError.unknownOpcode(value: opcodeRaw, atWord: i)
                    }

                    let insn = Instruction(opcode: opcode, parameter: parameter, rawWord: word, wordSize: wordSize)
                    let insnIndex = insns.count
                    insns.append(insn)
                    wordToInsn[i] = insnIndex
                    if wordSize == 2 { wordToInsn[i + 1] = insnIndex }
                    i += wordSize
                }
                return Program(
                    texts: texts,
                    entryPoints: entryPoints,
                    code: code,
                    instructions: insns,
                    wordIndexToInsn: wordToInsn
                )
            }

            /// Looks up the instruction that starts at a given word index.
            public func instruction(atWord word: Int) -> Instruction? {
                guard word >= 0, word < wordIndexToInsn.count else { return nil }
                let idx = wordIndexToInsn[word]
                guard idx >= 0, idx < instructions.count else { return nil }
                // Only return when this word is the *start* of the instruction.
                guard idx == 0 || wordIndexToInsn[word - 1] != idx else {
                    // Middle word of a 2-word insn; caller probably wants the start.
                    return instructions[idx]
                }
                return instructions[idx]
            }
        }

        // MARK: - Helpers

        private static func chunkAsBEWords(_ data: Data) -> [UInt16] {
            var out: [UInt16] = []
            out.reserveCapacity(data.count / 2)
            var i = data.startIndex
            while i + 1 < data.endIndex {
                out.append((UInt16(data[i]) << 8) | UInt16(data[i + 1]))
                i += 2
            }
            return out
        }

        private static func parseTextChunk(_ data: Data) throws -> [String] {
            guard data.count >= 2 else { return [] }
            let base = data.startIndex
            let firstOffset = (UInt16(data[base]) << 8) | UInt16(data[base + 1])
            let count = Int(firstOffset) / 2
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                let offsetByte = base + i * 2
                guard offsetByte + 1 < data.endIndex else { throw Program.DecodeError.truncated }
                let offset = Int((UInt16(data[offsetByte]) << 8) | UInt16(data[offsetByte + 1]))
                let stringStart = base + offset
                guard stringStart < data.endIndex else { throw Program.DecodeError.truncated }
                var end = stringStart
                while end < data.endIndex && data[end] != 0 { end += 1 }
                guard end < data.endIndex else { throw Program.DecodeError.truncated }
                let str = String(bytes: data[stringStart..<end], encoding: .ascii) ?? ""
                out.append(str)
            }
            return out
        }

        private static func readFourCC(_ data: Data, at offset: Int) -> String {
            let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }

        private static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }

        private static func readChunks(_ data: Data) throws -> [String: Data] {
            var chunks: [String: Data] = [:]
            var cursor = data.startIndex + 12 // past FORM + size + outer tag
            while cursor + 8 <= data.endIndex {
                let tag = readFourCC(data, at: cursor)
                let length = Int(readU32BE(data, at: cursor + 4))
                let dataStart = cursor + 8
                let dataEnd = dataStart + length
                guard dataEnd <= data.endIndex else { break }
                chunks[tag] = data.subdata(in: dataStart..<dataEnd)
                cursor = dataEnd + (length & 1)
            }
            return chunks
        }
    }
}
