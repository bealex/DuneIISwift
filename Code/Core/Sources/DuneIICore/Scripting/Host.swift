import Foundation

extension Scripting {
    /// Mutable context for host functions that read or write world state.
    /// Analogue of OpenDUNE's `g_scriptCurrentObject` / `g_scriptCurrentUnit`
    /// globals plus the script-info text table and the UI text queue.
    ///
    /// Reference type so host closures can mutate fields (e.g. append to
    /// `textLog`) while the `Engine` value type stays pure.
    public final class Host: @unchecked Sendable {
        public var units: Simulation.UnitPool
        public var structures: Simulation.StructurePool
        public var explosions: Simulation.ExplosionPool
        public var teams: Simulation.TeamPool
        /// Per-house credit + starport state. Slice 6a plumbed the
        /// fields onto `HouseSlot`; slice 6b makes them reachable at
        /// runtime for the scheduler's credit-drain pass and the
        /// scene's cancel-refund.
        public var houses: Simulation.HousePool
        /// The "current object" for the running script tick. `nil` when no
        /// object is selected (host functions that depend on it return
        /// their "no current object" path).
        public var currentObject: ObjectRef?
        /// `scriptInfo->text` analogue — the EMC program's text table,
        /// typically `Formats.Emc.Program.texts`.
        public var texts: [String]
        /// Sink for `Script_General_DisplayText` calls. Tests read this;
        /// live callers route elsewhere.
        public var textLog: [DisplayedText]
        /// Sink for `Script_General_VoicePlay` calls. One entry per call,
        /// in script-execution order.
        public var voiceLog: [VoicePlay]
        /// Per-tile enter-score provider for the pathfinder. Optional —
        /// when `nil`, `CalculateRoute` returns "no route" immediately.
        /// Callers wire this from a `Map` + `TileResolver` + pool state.
        public var tileEnterScore: ((_ packed: UInt16, _ orient8: UInt8, _ movementType: Simulation.MovementType) -> Int32)?
        /// `g_playerHouseID` analogue — identifies the local player for
        /// alliance checks. `nil` means "no player yet" — alliance
        /// degrades to strict equality. Read by target-priority math.
        public var playerHouseID: UInt8?
        /// `Map_IsValidPosition` analogue — returns `true` when a packed
        /// tile is within the playable map bounds. `nil` defaults to
        /// "always valid" (matches the full 64×64 scenario).
        public var isValidPosition: ((_ packed: UInt16) -> Bool)?
        /// `Map_IsPositionUnveiled` analogue — returns `true` when fog
        /// has been cleared at a packed tile. `nil` defaults to
        /// "always unveiled" (matches OpenDUNE's `g_debugScenario`).
        public var isPositionUnveiled: ((_ packed: UInt16) -> Bool)?
        /// `Map_GetLandscapeType` analogue — returns the `LandscapeType`
        /// raw value for a packed tile. `nil` means "unknown" — callers
        /// that use this for speed selection (`CalculateRoute` → the
        /// `Unit_StartMovement` speed path) skip the update and leave
        /// `slot.speed` alone so install-less tests keep working.
        public var landscapeAt: ((_ packed: UInt16) -> UInt8)?

        /// Runtime spice grid. When non-nil, the scheduler's harvesting
        /// pass reads `spiceMap.landscapeByte` to decide whether a
        /// harvester's current tile holds spice, and writes level
        /// transitions through `spiceMap.apply`. `nil` disables the
        /// pass entirely — tests that don't care about spice leave it
        /// `nil` and existing paths stay unaffected. See
        /// `Documentation/Algorithms/HarvesterSpiceDeposit.md`.
        public var spiceMap: Simulation.SpiceMap?

        /// Notifier fired by the scheduler whenever `spiceMap.apply`
        /// actually changes a cell's level (bare ↔ thin ↔ thick). Used
        /// by the runtime to rewrite the matching `tileGrid` cell's
        /// `groundTileID` so the scene / minimap / screenshot see
        /// drained tiles degrade in real time. `nil` = no repaint.
        /// See `Documentation/Algorithms/SpiceRepaint.md`.
        public var spiceLevelDidChange: ((_ packed: UInt16, _ level: Simulation.SpiceMap.Level) -> Void)?

        /// Direct override for a cell's `groundTileID`. Fired from the
        /// bloom-detonation path to reset a spice-bloom tile back to
        /// sand after it explodes (the bloom transition doesn't go
        /// through `SpiceMap.apply`). `nil` disables repaint — the
        /// sim state still mutates; only the view surface stays stale.
        public var groundTileOverride: ((_ packed: UInt16, _ tileID: UInt16) -> Void)?

        public enum ObjectRef: Sendable, Equatable {
            case unit(poolIndex: Int)
            case structure(poolIndex: Int)
            case team(poolIndex: Int)
        }

        public struct DisplayedText: Sendable, Equatable {
            public let text: String
            public let arg1: UInt16
            public let arg2: UInt16
            public let arg3: UInt16
        }

        public struct VoicePlay: Sendable, Equatable {
            /// Voice ID passed on the stack (0..255). OpenDUNE looks this
            /// up in its voice sample table.
            public let voiceID: UInt16
            public let positionX: UInt16
            public let positionY: UInt16
        }

        public init(
            units: Simulation.UnitPool = Simulation.UnitPool(),
            structures: Simulation.StructurePool = Simulation.StructurePool(),
            explosions: Simulation.ExplosionPool = Simulation.ExplosionPool(),
            teams: Simulation.TeamPool = Simulation.TeamPool(),
            houses: Simulation.HousePool = Simulation.HousePool(),
            currentObject: ObjectRef? = nil,
            texts: [String] = [],
            textLog: [DisplayedText] = [],
            voiceLog: [VoicePlay] = [],
            tileEnterScore: ((_ packed: UInt16, _ orient8: UInt8, _ movementType: Simulation.MovementType) -> Int32)? = nil,
            playerHouseID: UInt8? = nil,
            isValidPosition: ((_ packed: UInt16) -> Bool)? = nil,
            isPositionUnveiled: ((_ packed: UInt16) -> Bool)? = nil,
            landscapeAt: ((_ packed: UInt16) -> UInt8)? = nil,
            spiceMap: Simulation.SpiceMap? = nil,
            spiceLevelDidChange: ((_ packed: UInt16, _ level: Simulation.SpiceMap.Level) -> Void)? = nil,
            groundTileOverride: ((_ packed: UInt16, _ tileID: UInt16) -> Void)? = nil
        ) {
            self.units = units
            self.structures = structures
            self.explosions = explosions
            self.teams = teams
            self.houses = houses
            self.currentObject = currentObject
            self.texts = texts
            self.textLog = textLog
            self.voiceLog = voiceLog
            self.tileEnterScore = tileEnterScore
            self.playerHouseID = playerHouseID
            self.isValidPosition = isValidPosition
            self.isPositionUnveiled = isPositionUnveiled
            self.landscapeAt = landscapeAt
            self.spiceMap = spiceMap
            self.spiceLevelDidChange = spiceLevelDidChange
            self.groundTileOverride = groundTileOverride
        }

        // MARK: Convenience queries

        /// `houseID` of the current object, or `nil` when none is set.
        public var currentHouseID: UInt8? {
            switch currentObject {
            case .unit(let idx):
                guard idx >= 0, idx < units.slots.count, units.slots[idx].isUsed else { return nil }
                return units.slots[idx].houseID
            case .structure(let idx):
                guard idx >= 0, idx < structures.slots.count, structures.slots[idx].isUsed else { return nil }
                return structures.slots[idx].houseID
            case .team(let idx):
                guard idx >= 0, idx < teams.slots.count, teams.slots[idx].isUsed else { return nil }
                return teams.slots[idx].houseID
            case .none:
                return nil
            }
        }

        /// `houseID` of the object an encoded index points at, or `nil`
        /// when the index is invalid / freed / non-object.
        public func houseID(of encoded: EncodedIndex) -> UInt8? {
            let idx = Int(encoded.decoded)
            switch encoded.kind {
            case .unit:
                guard idx < units.slots.count else { return nil }
                let slot = units.slots[idx]
                guard slot.isUsed, slot.isAllocated else { return nil }
                return slot.houseID
            case .structure:
                guard idx < structures.slots.count else { return nil }
                let slot = structures.slots[idx]
                guard slot.isUsed else { return nil }
                return slot.houseID
            case .none, .tile:
                return nil
            }
        }

        /// Pulls the live unit slot referenced by an encoded index. Nil on
        /// anything other than a valid, used, allocated unit.
        public func unitSlot(for encoded: EncodedIndex) -> Simulation.UnitSlot? {
            guard encoded.kind == .unit else { return nil }
            let idx = Int(encoded.decoded)
            guard idx < units.slots.count else { return nil }
            let slot = units.slots[idx]
            guard slot.isUsed, slot.isAllocated else { return nil }
            return slot
        }
    }
}
