import Foundation

extension Simulation {
    public struct StructureSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var isAllocated: Bool
        public var index: UInt16
        public var type: UInt8
        public var houseID: UInt8
        public var linkedID: UInt8
        /// Signed structure state enum: `-2` DETECT (write-only sentinel),
        /// `-1` JUSTBUILT, `0` IDLE, `1` BUSY, `2` READY.
        public var state: Int16
        /// Production / unload countdown. Read by `Script_Structure_SetState`
        /// during DETECT resolution.
        public var countDown: UInt16
        /// Tile32 pixel-coordinate position of the structure's upper-left
        /// cell's centre. Structures span 1..6 tiles; `positionX/Y` is the
        /// anchor, not the centre of the full footprint.
        public var positionX: UInt16
        public var positionY: UInt16
        /// Current hitpoints; `0` means destroyed.
        public var hitpoints: UInt16
        /// Max hitpoints. Seeded on `Structure_Create` from the type's
        /// table value; damage reduces `hitpoints` but never touches
        /// this. Needed separately because some structures degrade
        /// (missing concrete slab) and spawn with `hitpoints <
        /// hitpointsMax`.
        public var hitpointsMax: UInt16
        /// Factory upgrade level, 0..3. Seeded on `Structure_Create`
        /// (Harkonnen LIGHT_VEHICLE → 1; else 0). Read by the
        /// buildable-structure / buildable-unit logic. AI houses get
        /// their max campaign-gated level via an auto-upgrade loop in
        /// `Structure_Create` that we haven't ported yet.
        public var upgradeLevel: UInt8
        /// Current production queue item for factory structures;
        /// `0xFFFF` = nothing being built. Seeded to `0xFFFF` on
        /// `Structure_Create`. Written by `Structure_BuildObject`
        /// (deferred).
        public var objectType: UInt16
        /// Current 8-step turret rotation `0..7` (N, NE, E, SE, S, SW, W, NW).
        /// Read by `Script_Structure_RotateTurret` / `GetDirection` and
        /// written on each turret-rotate tick. Non-turret structures
        /// leave this at 0.
        public var rotationSpriteDiff: UInt8
        /// Mirror of `ObjectFlags.degrades` (save bit `0x0400`). Set
        /// when a structure spawns without full slab support (slice 4c
        /// HP-degradation path) or is otherwise marked to lose HP over
        /// time. Slice 4c sets it on degraded placements; the per-tick
        /// decay consumer is a later slice.
        public var degrades: Bool
        /// Player-set rally tile, packed as `y * 64 + x`. Sentinel
        /// `0xFFFF` means "unset" (default). Only factories consult
        /// this field; non-factory structures ignore it. Set via
        /// `Simulation.Structures.setRallyPoint`. Not persisted across
        /// saves — a UI-layer convenience, not a logic-parity field.
        public var rallyPointPacked: UInt16
        /// `o.script.variables[4]` shadow on the slot. OpenDUNE's
        /// `Object_Script_Variable4_Set` writes the engine variable
        /// directly; Swift mirrors it onto the slot so the pathfinder
        /// + tile-enter score can read it without touching engine
        /// state. `0` means "no link". The structure-side companion
        /// to `UnitSlot.scriptVariable4` — `Object_Script_Variable4_Link`
        /// updates both.
        ///
        /// Read by the parity-harness `tileEnterScore` wrapper to
        /// distinguish the post-link `Unit_IsValidMovementIntoStructure`
        /// return of 2 (variables[4] points back at the calling unit;
        /// score = -2 → `Unit_StartMovement` accepts) from the pre-link
        /// return of 1 (score = -1 → `Unit_StartMovement` rejects).
        /// SAVE007 tick 5436 surfaced this: u39's 3rd east step into
        /// the refinery footprint needs the score=-2 path because the
        /// refinery and harvester are already linked via SetDestination.
        public var scriptVariable4: UInt16

        public init(
            isUsed: Bool = false,
            isAllocated: Bool = false,
            index: UInt16 = 0,
            type: UInt8 = 0,
            houseID: UInt8 = 0,
            linkedID: UInt8 = 0,
            state: Int16 = 0,
            countDown: UInt16 = 0,
            positionX: UInt16 = 0,
            positionY: UInt16 = 0,
            hitpoints: UInt16 = 0,
            hitpointsMax: UInt16 = 0,
            upgradeLevel: UInt8 = 0,
            objectType: UInt16 = 0xFFFF,
            rotationSpriteDiff: UInt8 = 0,
            degrades: Bool = false,
            rallyPointPacked: UInt16 = 0xFFFF,
            scriptVariable4: UInt16 = 0
        ) {
            self.isUsed = isUsed
            self.isAllocated = isAllocated
            self.index = index
            self.type = type
            self.houseID = houseID
            self.linkedID = linkedID
            self.state = state
            self.countDown = countDown
            self.positionX = positionX
            self.positionY = positionY
            self.hitpoints = hitpoints
            self.hitpointsMax = hitpointsMax
            self.upgradeLevel = upgradeLevel
            self.objectType = objectType
            self.rotationSpriteDiff = rotationSpriteDiff
            self.degrades = degrades
            self.rallyPointPacked = rallyPointPacked
            self.scriptVariable4 = scriptVariable4
        }
    }

    public struct StructurePool: Sendable, Equatable {
        public static let capacityHard = 82
        public static let capacitySoft = 79
        public static let indexWall = 79
        public static let indexSlab2x2 = 80
        public static let indexSlab1x1 = 81
        public static let invalidIndex: UInt16 = 0xFFFF

        public private(set) var slots: [StructureSlot]
        public private(set) var findArray: [Int]

        public init() {
            self.slots = Array(repeating: StructureSlot(), count: Self.capacityHard)
            self.findArray = []
        }

        public subscript(index: Int) -> StructureSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        @discardableResult
        public mutating func allocate(at index: Int, type: UInt8, houseID: UInt8) -> Int? {
            guard index >= 0, index < Self.capacitySoft else { return nil }
            guard !slots[index].isUsed else { return nil }
            slots[index] = StructureSlot(
                isUsed: true,
                isAllocated: true,
                index: UInt16(index),
                type: type,
                houseID: houseID,
                linkedID: 0xFF
            )
            findArray.append(index)
            return index
        }

        @discardableResult
        public mutating func allocate(in range: ClosedRange<Int>, type: UInt8, houseID: UInt8) -> Int? {
            for index in range where index >= 0 && index < Self.capacitySoft && !slots[index].isUsed {
                return allocate(at: index, type: type, houseID: houseID)
            }
            return nil
        }

        /// Re-initialises one of the three reserved aggregate slots
        /// (`indexWall`, `indexSlab2x2`, `indexSlab1x1`). Always succeeds;
        /// previous content is discarded. Does NOT touch `findArray`.
        @discardableResult
        public mutating func allocateReserved(at index: Int, type: UInt8) -> Int {
            precondition(
                index == Self.indexWall || index == Self.indexSlab2x2 || index == Self.indexSlab1x1,
                "allocateReserved called with non-reserved index \(index)"
            )
            slots[index] = StructureSlot(
                isUsed: true,
                isAllocated: true,
                index: UInt16(index),
                type: type,
                houseID: 0,
                linkedID: 0xFF
            )
            return index
        }

        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacityHard, slots[index].isUsed else { return }
            slots[index].isUsed = false
            slots[index].isAllocated = false
            // Reserved slots never appear in the findArray; only normal slots
            // need to be removed from it.
            if index < Self.capacitySoft, let position = findArray.firstIndex(of: index) {
                findArray.remove(at: position)
            }
        }
    }
}
