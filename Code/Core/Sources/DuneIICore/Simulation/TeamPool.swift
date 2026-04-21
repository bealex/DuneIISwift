import Foundation

extension Simulation {
    /// Port of OpenDUNE `TeamActionType` (`src/team.h:11`). Drives how
    /// a team's members behave — `KAMIKAZE` teams prefer structures via
    /// `FindBestTarget(mode: 4)`, everyone else uses `mode: 0`.
    public enum TeamAction: UInt8, Sendable, Equatable {
        case normal   = 0
        case staging  = 1
        case flee     = 2
        case kamikaze = 3
        case guard_   = 4

        public static let invalid: UInt8 = 0xFF
    }

    /// Value-type mirror of `Team` (`src/team.h:34`). Trimmed to what
    /// our wired script slots read; unported behavior (tile→average
    /// position, script engine, individual member linkage) lands with
    /// follow-up slices. See `Documentation/Algorithms/TeamAI.md` (TBD).
    public struct TeamSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var index: UInt16
        public var members: UInt16
        /// `minMembers` — EMC reads this as `Script_Team_GetVariable6`
        /// (the name is a misnomer in OpenDUNE; it's really the lower
        /// member-count bound the team tries to maintain).
        public var minMembers: UInt16
        public var maxMembers: UInt16
        /// Constrains which unit movement types may join this team.
        /// Matches the save record's `movementType: UInt16`.
        public var movementType: UInt16
        /// Current `TeamAction.rawValue`. `Script_Team_Load` swaps this
        /// to transition to a new team-level behaviour (e.g. STAGING →
        /// KAMIKAZE once the team is full).
        public var action: UInt16
        public var actionStart: UInt16
        public var houseID: UInt8
        /// Team's notional position — the average of its members'
        /// positions after `GetAverageDistance` runs. Initially the
        /// spawn anchor.
        public var positionX: UInt16
        public var positionY: UInt16
        /// Encoded target + a "target is useful" gate tile. `0` when no
        /// target is locked.
        public var targetTile: UInt16
        public var target: UInt16

        public init(
            isUsed: Bool = false,
            index: UInt16 = 0,
            members: UInt16 = 0,
            minMembers: UInt16 = 0,
            maxMembers: UInt16 = 0,
            movementType: UInt16 = 0,
            action: UInt16 = 0,
            actionStart: UInt16 = 0,
            houseID: UInt8 = 0xFF,
            positionX: UInt16 = 0,
            positionY: UInt16 = 0,
            targetTile: UInt16 = 0,
            target: UInt16 = 0
        ) {
            self.isUsed = isUsed
            self.index = index
            self.members = members
            self.minMembers = minMembers
            self.maxMembers = maxMembers
            self.movementType = movementType
            self.action = action
            self.actionStart = actionStart
            self.houseID = houseID
            self.positionX = positionX
            self.positionY = positionY
            self.targetTile = targetTile
            self.target = target
        }
    }

    public struct TeamPool: Sendable, Equatable {
        /// `TEAM_INDEX_MAX` from `src/pool/team.h:7`.
        public static let capacity = 16
        public static let invalidIndex: UInt16 = 0xFFFF

        public private(set) var slots: [TeamSlot]
        public private(set) var findArray: [Int]

        public init() {
            self.slots = Array(repeating: TeamSlot(), count: Self.capacity)
            self.findArray = []
        }

        public subscript(index: Int) -> TeamSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        @discardableResult
        public mutating func allocate(
            at index: Int,
            houseID: UInt8,
            action: TeamAction,
            movementType: UInt16,
            minMembers: UInt16,
            maxMembers: UInt16,
            position: Pos32 = Pos32(x: 0, y: 0)
        ) -> Int? {
            guard index >= 0, index < Self.capacity else { return nil }
            guard !slots[index].isUsed else { return nil }
            slots[index] = TeamSlot(
                isUsed: true,
                index: UInt16(index),
                minMembers: minMembers,
                maxMembers: maxMembers,
                movementType: movementType,
                action: UInt16(action.rawValue),
                actionStart: UInt16(action.rawValue),
                houseID: houseID,
                positionX: position.x,
                positionY: position.y
            )
            findArray.append(index)
            return index
        }

        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacity, slots[index].isUsed else { return }
            slots[index].isUsed = false
            if let position = findArray.firstIndex(of: index) {
                findArray.remove(at: position)
            }
        }
    }
}
