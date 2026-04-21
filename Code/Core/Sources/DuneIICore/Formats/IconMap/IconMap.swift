import Foundation

extension Formats {
    /// Companion to `ICON.ICN`. A flat `UInt16` array whose first 28 entries
    /// are indices (back into the same array) that partition the remaining
    /// values into "icon groups" — walls, fog, spice bloom, etc. See
    /// `Documentation/Formats/MAP.md` for the full layout.
    public struct IconMap: Sendable {
        /// Raw u16 LE values as they appear on disk.
        public let raw: [UInt16]

        public var groupCount: Int { Group.allCases.count }

        /// Enum values match OpenDUNE's `ICM_ICONGROUP_*` order exactly so
        /// `.rawValue` is the index used inside the map's group header.
        public enum Group: Int, Sendable, CaseIterable {
            case unused = 0
            case rockCraters = 1
            case sandCraters = 2
            case flyMachinesCrash = 3
            case sandDeadBodies = 4
            case sandTracks = 5
            case walls = 6
            case fogOfWar = 7
            case concreteSlab = 8
            case landscape = 9
            case spiceBloom = 10
            case housePalace = 11
            case lightVehicleFactory = 12
            case heavyVehicleFactory = 13
            case hiTechFactory = 14
            case ixResearch = 15
            case worTrooperFacility = 16
            case constructionYard = 17
            case infantryBarracks = 18
            case windtrapPower = 19
            case starportFacility = 20
            case spiceRefinery = 21
            case vehicleRepairCentre = 22
            case baseDefenseTurret = 23
            case baseRocketTurret = 24
            case spiceStorageSilo = 25
            case radarOutpost = 26
            case eof = 27
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case truncated
            case headerTooSmall(entries: Int)
        }

        public static func decode(_ data: Data) throws -> IconMap {
            guard data.count % 2 == 0 else { throw DecodeError.truncated }
            let count = data.count / 2
            // The group header is 28 u16s, so a valid file must hold at least
            // that much. Real files always carry tile IDs after the header,
            // but we accept a bare header as edge-case valid.
            guard count >= Group.allCases.count else {
                throw DecodeError.headerTooSmall(entries: count)
            }
            var values = [UInt16](repeating: 0, count: count)
            data.withUnsafeBytes { rawBuf in
                let src = rawBuf.bindMemory(to: UInt8.self)
                for i in 0..<count {
                    values[i] = UInt16(src[i * 2]) | (UInt16(src[i * 2 + 1]) << 8)
                }
            }
            return IconMap(raw: values)
        }

        /// Returns the slice of tile IDs belonging to `group`. Uses the OpenDUNE
        /// convention: group `g` spans `raw[raw[g] ..< raw[g+1]]`.
        public func tileIds(in group: Group) -> [UInt16] {
            let index = group.rawValue
            guard index + 1 < raw.count else { return [] }
            let start = Int(raw[index])
            let end = Int(raw[index + 1])
            guard start <= end, end <= raw.count else { return [] }
            return Array(raw[start..<end])
        }

        /// The `k`-th tile ID within `group`, matching OpenDUNE's idiom
        /// `g_iconMap[g_iconMap[G] + k]`. Precondition: `offset` is within
        /// the group's range.
        public func tileId(in group: Group, offset: Int) -> UInt16 {
            let base = Int(raw[group.rawValue])
            return raw[base + offset]
        }
    }
}
