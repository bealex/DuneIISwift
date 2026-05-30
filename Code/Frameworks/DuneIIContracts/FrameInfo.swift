/// An immutable, presentation-neutral snapshot the simulation hands the renderer (and the verification
/// panels) once per drawn frame — the `sim → render` half of the Contracts seam (`Command` is the input
/// half, `SoundEvent` the audio half). The `SpriteKitRenderer` is a pure function of a `FrameInfo`: it
/// never reads simulation internals, so it stays a mockable leaf and can be driven from a recorded
/// snapshot. Produced by `Simulation.makeFrameInfo()`; consumed by renderer / UI panels.
///
/// Conventions (see `Documentation/Architecture/FrameInfo.md`):
/// - **Positions** are world **sub-tile units** (256 per tile, the native `tile32` space). The renderer
///   converts with `px = pos * tilePx / 256` and subtracts the viewport origin (same space).
/// - **Sprites** are **global indices** into the concatenated SHPs; the renderer maps index → SHP+frame.
/// - **Houses** are the effective house (`Unit_GetHouseID` — deviation is already applied).
public struct FrameInfo: Sendable, Equatable {
    /// The game clock (`g_timerGame`) at the snapshot.
    public var tick: UInt32
    public var mapWidth: Int
    public var mapHeight: Int

    /// Row-major `mapWidth * mapHeight` terrain. Structures are baked into the ground tiles by
    /// `Structure_UpdateMap`, so this layer already draws buildings — the renderer needs no separate
    /// structure-sprite pass.
    public var tiles: [Tile]
    public var units: [Unit]
    /// Structures for the inspector / selection; the renderer draws them from `tiles`.
    public var structures: [Structure]
    /// Transient overlays: active explosions + smoke over damaged vehicles.
    public var effects: [Effect]
    public var houses: [House]

    /// The viewport's top-left in world sub-tile units (same space as entity positions).
    public var viewportX: Int
    public var viewportY: Int

    public init(tick: UInt32, mapWidth: Int, mapHeight: Int, tiles: [Tile], units: [Unit],
                structures: [Structure], effects: [Effect], houses: [House],
                viewportX: Int, viewportY: Int) {
        self.tick = tick
        self.mapWidth = mapWidth
        self.mapHeight = mapHeight
        self.tiles = tiles
        self.units = units
        self.structures = structures
        self.effects = effects
        self.houses = houses
        self.viewportX = viewportX
        self.viewportY = viewportY
    }

    /// One map cell: the ground icon, an optional overlay (spice/walls), and the player-fog state.
    public struct Tile: Sendable, Equatable {
        public var groundSpriteIndex: Int
        /// 0 = no overlay.
        public var overlaySpriteIndex: Int
        /// `false` = under fog of war in the player's view.
        public var isUnveiled: Bool

        public init(groundSpriteIndex: Int, overlaySpriteIndex: Int, isUnveiled: Bool) {
            self.groundSpriteIndex = groundSpriteIndex
            self.overlaySpriteIndex = overlaySpriteIndex
            self.isUnveiled = isUnveiled
        }
    }

    public struct Unit: Sendable, Equatable {
        public var id: UInt16
        public var type: UnitType
        public var house: HouseID
        public var positionX: Int
        public var positionY: Int
        public var body: SpriteLayer
        public var turret: SpriteLayer?
        public var isSmoking: Bool
        public var hitpoints: Int
        public var hitpointsMax: Int

        public init(id: UInt16, type: UnitType, house: HouseID, positionX: Int, positionY: Int,
                    body: SpriteLayer, turret: SpriteLayer?, isSmoking: Bool,
                    hitpoints: Int, hitpointsMax: Int) {
            self.id = id
            self.type = type
            self.house = house
            self.positionX = positionX
            self.positionY = positionY
            self.body = body
            self.turret = turret
            self.isSmoking = isSmoking
            self.hitpoints = hitpoints
            self.hitpointsMax = hitpointsMax
        }
    }

    public struct Structure: Sendable, Equatable {
        public var id: UInt16
        public var type: StructureType
        public var house: HouseID
        /// The tile **corner** (`Structure_Place: position &= 0xFF00`), in sub-tile units.
        public var positionX: Int
        public var positionY: Int
        public var hitpoints: Int
        public var hitpointsMax: Int

        public init(id: UInt16, type: StructureType, house: HouseID, positionX: Int, positionY: Int,
                    hitpoints: Int, hitpointsMax: Int) {
            self.id = id
            self.type = type
            self.house = house
            self.positionX = positionX
            self.positionY = positionY
            self.hitpoints = hitpoints
            self.hitpointsMax = hitpointsMax
        }
    }

    /// A transient overlay sprite (explosion frame or smoke), at a world position.
    public struct Effect: Sendable, Equatable {
        public var positionX: Int
        public var positionY: Int
        public var sprite: SpriteLayer

        public init(positionX: Int, positionY: Int, sprite: SpriteLayer) {
            self.positionX = positionX
            self.positionY = positionY
            self.sprite = sprite
        }
    }

    public struct House: Sendable, Equatable {
        public var id: HouseID
        public var credits: Int
        public var creditsStorage: Int
        public var powerProduction: Int
        public var powerUsage: Int

        public init(id: HouseID, credits: Int, creditsStorage: Int,
                    powerProduction: Int, powerUsage: Int) {
            self.id = id
            self.credits = credits
            self.creditsStorage = creditsStorage
            self.powerProduction = powerProduction
            self.powerUsage = powerUsage
        }
    }
}
