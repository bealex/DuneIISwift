import Foundation

extension Formats.Save {
    /// Body of the `INFO` chunk in `_SAVE00?.DAT`.
    ///
    /// Wire layout documented in `Documentation/Formats/SAVE.md` §7. Everything
    /// after the 2-byte little-endian version word is a flat dump of OpenDUNE's
    /// `s_saveInfo` table (`src/saveload/info.c`), which nests `g_saveScenario`
    /// (`src/saveload/scenario.c`).
    public struct Info: Sendable, Equatable {
        public let version: UInt16
        public let scenario: Scenario

        // Top-level player / UI state
        public let playerCreditsNoSilo: UInt16
        public let minimapPosition: UInt16
        public let selectionRectanglePosition: UInt16
        public let selectionType: Int8
        public let structureActiveType: Int8
        public let structureActivePosition: UInt16
        public let structureActiveIndex: UInt16
        public let unitSelectedIndex: UInt16
        public let unitActiveIndex: UInt16
        public let activeAction: UInt16
        public let strategicRegionBits: UInt32
        public let scenarioID: UInt16
        public let campaignID: UInt16
        public let hintsShown1: UInt32
        public let hintsShown2: UInt32
        /// Delta `g_timerGame - g_tickScenarioStart` at save time.
        public let scenarioElapsedTicks: UInt32
        /// 27-entry `int16` array; `-1` means "stock unknown".
        public let starportAvailable: [Int16]
        public let houseMissileCountdown: UInt16
        public let unitHouseMissileIndex: UInt16
        public let structureIndex: UInt16

        public struct Scenario: Sendable, Equatable {
            public let score: UInt16
            public let winFlags: UInt16
            public let loseFlags: UInt16
            public let mapSeed: UInt32
            public let mapScale: UInt16
            public let timeOut: UInt16
            public let pictureBriefing: String
            public let pictureWin: String
            public let pictureLose: String
            public let killedAllied: UInt16
            public let killedEnemy: UInt16
            public let destroyedAllied: UInt16
            public let destroyedEnemy: UInt16
            public let harvestedAllied: UInt16
            public let harvestedEnemy: UInt16
            public let reinforcement: [Reinforcement]
        }

        public struct Reinforcement: Sendable, Equatable {
            public let unitID: UInt16
            public let locationID: UInt16
            public let timeLeft: UInt16
            public let timeBetween: UInt16
            /// `repeat` is a keyword in Swift; renamed to `repeats`.
            public let repeats: UInt16
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case truncated
            /// Leading version word was not `0x0290` — the file was written by
            /// a pre-1.07 Westwood build. OpenDUNE routes these through a
            /// separate `s_saveInfoOld` table; we surface that as a legacy
            /// decode path rather than silently mis-aligning every field.
            case legacyVersion(version: UInt16)
        }

        /// Expected chunk body size for modern (`0x0290`) saves:
        /// 2-byte version + 228-byte scenario block + 100-byte top-level block.
        public static let modernBodySize = 330

        public static func decode(_ body: Data) throws -> Info {
            guard body.count >= 2 else { throw DecodeError.truncated }
            let base = body.startIndex
            let version = readU16LE(body, at: base)

            if version != 0x0290 {
                throw DecodeError.legacyVersion(version: version)
            }

            guard body.count >= modernBodySize else { throw DecodeError.truncated }

            var cursor = base + 2
            let scenario = readScenario(body, cursor: &cursor)

            let playerCreditsNoSiloFirst = readU16LE(body, at: cursor); cursor += 2
            _ = playerCreditsNoSiloFirst // overwritten by the duplicate at offset 266

            let minimapPosition = readU16LE(body, at: cursor); cursor += 2
            let selectionRectanglePosition = readU16LE(body, at: cursor); cursor += 2
            let selectionType = Int8(bitPattern: body[cursor]); cursor += 1
            let structureActiveType = Int8(bitPattern: body[cursor]); cursor += 1
            let structureActivePosition = readU16LE(body, at: cursor); cursor += 2
            let structureActiveIndex = readU16LE(body, at: cursor); cursor += 2
            let unitSelectedIndex = readU16LE(body, at: cursor); cursor += 2
            let unitActiveIndex = readU16LE(body, at: cursor); cursor += 2
            let activeAction = readU16LE(body, at: cursor); cursor += 2
            let strategicRegionBits = readU32LE(body, at: cursor); cursor += 4
            let scenarioID = readU16LE(body, at: cursor); cursor += 2
            let campaignID = readU16LE(body, at: cursor); cursor += 2
            let hintsShown1 = readU32LE(body, at: cursor); cursor += 4
            let hintsShown2 = readU32LE(body, at: cursor); cursor += 4
            let scenarioElapsedTicks = readU32LE(body, at: cursor); cursor += 4

            // Duplicate slot — second write wins, matching OpenDUNE.
            let playerCreditsNoSilo = readU16LE(body, at: cursor); cursor += 2

            var starport = [Int16](); starport.reserveCapacity(27)
            for _ in 0..<27 {
                starport.append(Int16(bitPattern: readU16LE(body, at: cursor)))
                cursor += 2
            }
            let houseMissileCountdown = readU16LE(body, at: cursor); cursor += 2
            let unitHouseMissileIndex = readU16LE(body, at: cursor); cursor += 2
            let structureIndex = readU16LE(body, at: cursor); cursor += 2

            return Info(
                version: version,
                scenario: scenario,
                playerCreditsNoSilo: playerCreditsNoSilo,
                minimapPosition: minimapPosition,
                selectionRectanglePosition: selectionRectanglePosition,
                selectionType: selectionType,
                structureActiveType: structureActiveType,
                structureActivePosition: structureActivePosition,
                structureActiveIndex: structureActiveIndex,
                unitSelectedIndex: unitSelectedIndex,
                unitActiveIndex: unitActiveIndex,
                activeAction: activeAction,
                strategicRegionBits: strategicRegionBits,
                scenarioID: scenarioID,
                campaignID: campaignID,
                hintsShown1: hintsShown1,
                hintsShown2: hintsShown2,
                scenarioElapsedTicks: scenarioElapsedTicks,
                starportAvailable: starport,
                houseMissileCountdown: houseMissileCountdown,
                unitHouseMissileIndex: unitHouseMissileIndex,
                structureIndex: structureIndex
            )
        }

        // MARK: - Helpers

        private static func readScenario(_ body: Data, cursor: inout Int) -> Scenario {
            let score = readU16LE(body, at: cursor); cursor += 2
            let winFlags = readU16LE(body, at: cursor); cursor += 2
            let loseFlags = readU16LE(body, at: cursor); cursor += 2
            let mapSeed = readU32LE(body, at: cursor); cursor += 4
            let mapScale = readU16LE(body, at: cursor); cursor += 2
            let timeOut = readU16LE(body, at: cursor); cursor += 2
            let pictureBriefing = readNulPaddedString(body, at: cursor, count: 14); cursor += 14
            let pictureWin = readNulPaddedString(body, at: cursor, count: 14); cursor += 14
            let pictureLose = readNulPaddedString(body, at: cursor, count: 14); cursor += 14
            let killedAllied = readU16LE(body, at: cursor); cursor += 2
            let killedEnemy = readU16LE(body, at: cursor); cursor += 2
            let destroyedAllied = readU16LE(body, at: cursor); cursor += 2
            let destroyedEnemy = readU16LE(body, at: cursor); cursor += 2
            let harvestedAllied = readU16LE(body, at: cursor); cursor += 2
            let harvestedEnemy = readU16LE(body, at: cursor); cursor += 2

            var reinforcement: [Reinforcement] = []
            reinforcement.reserveCapacity(16)
            for _ in 0..<16 {
                let unitID = readU16LE(body, at: cursor); cursor += 2
                let locationID = readU16LE(body, at: cursor); cursor += 2
                let timeLeft = readU16LE(body, at: cursor); cursor += 2
                let timeBetween = readU16LE(body, at: cursor); cursor += 2
                let repeats = readU16LE(body, at: cursor); cursor += 2
                reinforcement.append(Reinforcement(
                    unitID: unitID,
                    locationID: locationID,
                    timeLeft: timeLeft,
                    timeBetween: timeBetween,
                    repeats: repeats
                ))
            }

            return Scenario(
                score: score,
                winFlags: winFlags,
                loseFlags: loseFlags,
                mapSeed: mapSeed,
                mapScale: mapScale,
                timeOut: timeOut,
                pictureBriefing: pictureBriefing,
                pictureWin: pictureWin,
                pictureLose: pictureLose,
                killedAllied: killedAllied,
                killedEnemy: killedEnemy,
                destroyedAllied: destroyedAllied,
                destroyedEnemy: destroyedEnemy,
                harvestedAllied: harvestedAllied,
                harvestedEnemy: harvestedEnemy,
                reinforcement: reinforcement
            )
        }

        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }

        private static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        private static func readNulPaddedString(_ data: Data, at offset: Int, count: Int) -> String {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for i in 0..<count {
                let byte = data[offset + i]
                if byte == 0 { break }
                bytes.append(byte)
            }
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }
    }
}
