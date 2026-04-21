import Foundation

extension Formats.Save {
    /// Top-level aggregator over a complete `_SAVE00?.DAT` file. Walks the
    /// IFF container and routes each required body through its dedicated
    /// decoder.
    ///
    /// Contract: `Documentation/Formats/SAVE.md` §12.
    public struct Game: Sendable, Equatable {
        /// ASCII contents of the `NAME` chunk, stripped of the trailing NUL.
        public let description: String
        public let info: Info
        public let houses: Player
        public let units: Units
        public let structures: Structures
        public let tileMap: TileMap
        /// `TEAM` body, present only when the running scenario had AI teams.
        public let team: Data?
        /// `ODUN` body, present only when the save was written by OpenDUNE
        /// (vanilla 1.07 never emits this — see
        /// `format-save-odun-is-opendune-only.md`).
        public let unitsNew: Data?

        public enum DecodeError: Error, Equatable, Sendable {
            case container(Container.DecodeError)
            case missingRequiredChunk(tag: String)
            case nameNotAscii
            case info(Info.DecodeError)
            case player(Player.DecodeError)
            case units(Units.DecodeError)
            case structures(Structures.DecodeError)
            case tileMap(TileMap.DecodeError)
        }

        public static let requiredChunkTags: [String] =
            ["NAME", "INFO", "PLYR", "UNIT", "BLDG", "MAP "]

        public static func decode(_ data: Data) throws -> Game {
            let container: Container
            do {
                container = try Container.decode(data)
            } catch let err as Container.DecodeError {
                throw DecodeError.container(err)
            }

            func requireChunk(_ tag: String) throws -> Data {
                guard let body = container.chunk(named: tag) else {
                    throw DecodeError.missingRequiredChunk(tag: tag)
                }
                return body
            }

            let nameBody = try requireChunk("NAME")
            let description = try decodeName(nameBody)

            let infoBody = try requireChunk("INFO")
            let info: Info
            do { info = try Info.decode(infoBody) }
            catch let err as Info.DecodeError { throw DecodeError.info(err) }

            let plyrBody = try requireChunk("PLYR")
            let houses: Player
            do { houses = try Player.decode(plyrBody) }
            catch let err as Player.DecodeError { throw DecodeError.player(err) }

            let unitBody = try requireChunk("UNIT")
            let units: Units
            do { units = try Units.decode(unitBody) }
            catch let err as Units.DecodeError { throw DecodeError.units(err) }

            let bldgBody = try requireChunk("BLDG")
            let structures: Structures
            do { structures = try Structures.decode(bldgBody) }
            catch let err as Structures.DecodeError { throw DecodeError.structures(err) }

            let mapBody = try requireChunk("MAP ")
            let tileMap: TileMap
            do { tileMap = try TileMap.decode(mapBody) }
            catch let err as TileMap.DecodeError { throw DecodeError.tileMap(err) }

            return Game(
                description: description,
                info: info,
                houses: houses,
                units: units,
                structures: structures,
                tileMap: tileMap,
                team: container.chunk(named: "TEAM"),
                unitsNew: container.chunk(named: "ODUN")
            )
        }

        private static func decodeName(_ body: Data) throws -> String {
            // NAME is NUL-terminated ASCII. Slice off the NUL and everything
            // past it — the writer always emits exactly one trailing NUL.
            var bytes: [UInt8] = []
            bytes.reserveCapacity(body.count)
            for i in body.indices {
                let b = body[i]
                if b == 0 { break }
                if b >= 0x80 { throw DecodeError.nameNotAscii }
                bytes.append(b)
            }
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }
    }
}
