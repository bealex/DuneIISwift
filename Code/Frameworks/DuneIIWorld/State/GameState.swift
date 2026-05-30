import DuneIIContracts
import DuneIIFormats

/// "Next-due" tick timestamps for each `GameLoop_Unit` sub-activity (OpenDUNE's `s_tickUnit*`).
/// An activity fires when its cursor is `<= timerGame`, then advances by its interval.
public struct UnitTickCursors: Sendable, Equatable {
    public var movement: UInt32 = 0
    public var rotation: UInt32 = 0
    public var blinking: UInt32 = 0
    public var unknown4: UInt32 = 0
    public var script: UInt32 = 0
    public var unknown5: UInt32 = 0
    public var deviation: UInt32 = 0
    public init() {}
}

/// The single owned aggregate of all mutable simulation state (engine principle 4). A port of the
/// OpenDUNE globals: the object pools (`g_unitArray`/`g_structureArray`/`g_houseArray`/`g_teamArray`
/// + their find arrays), the `g_map[64*64]` grid, both RNGs, and the two tick clocks.
///
/// It is a value type, so copying a `GameState` is a full snapshot. Code mutates objects in place via
/// their pool index (e.g. `state.units[i].o.hitpoints = …`). See `Documentation/Architecture/DataModel.md`.
public struct GameState: Sendable {
    // Object pools — fixed-size slot arrays sized to OpenDUNE's *_INDEX_MAX.
    public var units: [Unit]
    public var structures: [Structure]   // sized to MAX_HARD so the 3 special slots (79/80/81) exist
    public var houses: [House]
    public var teams: [Team]

    // Insertion-order indices of allocated items — OpenDUNE's `g_*FindArray` / `g_*FindCount`.
    var unitFindArray: [UInt16] = []
    var structureFindArray: [UInt16] = []
    var houseFindArray: [UInt16] = []
    var teamFindArray: [UInt16] = []

    /// The 64×64 map grid (`g_map`).
    public var map: [MapTile]

    /// The two RNGs (`Tools_Random_256` / `Tools_RandomLCG`).
    public var random256: Random256
    public var randomLCG: RandomLCG

    /// The two clocks: `g_timerGame` (simulation) and `g_timerGUI`.
    public var timerGame: UInt32 = 0
    public var timerGUI: UInt32 = 0

    /// Game speed (0 slowest … 4 fastest; 2 = normal). Scales durations via `Tools_AdjustToGameSpeed`,
    /// not the tick counters. OpenDUNE's `g_gameConfig.gameSpeed`.
    public var gameSpeed: UInt16 = 2

    /// When set, `timerGame` freezes and the game-loop phases don't run (`timerGUI` still advances).
    /// OpenDUNE's `TIMER_GAME` disable.
    public var paused = false

    /// Per-subsystem "next-due" tick cursors for `GameLoop_Unit` (OpenDUNE's `s_tickUnit*` statics).
    public var unitTick = UnitTickCursors()

    /// OpenDUNE's `g_validateStrictIfZero`: 0 = strict validation (normal play); non-zero bypasses the
    /// allocate / placement guards (used while loading a save or scenario).
    public var validateStrictIfZero: UInt16 = 0

    /// Scenario map scale (0 = 62×62, 1 = 32×32, 2 = 21×21). OpenDUNE's `g_scenario.mapScale`; indexes
    /// `MapInfo.scales`. Set by scenario loading (not yet ported).
    public var mapScale: UInt8 = 0

    /// The local player's house. OpenDUNE's `g_playerHouseID`; set by scenario loading (not yet ported).
    public var playerHouseID: UInt8 = 0

    /// The map viewport's top-left packed tile (OpenDUNE's `g_viewportPosition`). Render state, but it
    /// feeds the deterministic sim: `GameLoop_Unit` throttles an off-viewport unit's script to 3
    /// opcodes/tick (`Map_IsPositionInViewport`). Set by the host (camera) / the parity harness.
    public var viewportPosition: UInt16 = 0

    /// Runtime tile-id bases derived from `ICON.MAP` (`Sprites_Init`); populated at load. Anchors
    /// `Map_GetLandscapeType` etc.
    public var tileIDs = TileIDs()

    /// The decoded `ICON.MAP`, kept for the animation engine's icon-group tile lookups. Set at load.
    public var iconMap: IconMap?

    /// Active structure animations (`g_animations`, 112 slots).
    public var animations = [Animation](repeating: Animation(), count: 112)

    /// `s_animationTimer`: the next tick the animation pass needs to run.
    public var animationTimer: UInt32 = 0

    /// The seed-generated base ground tile of each cell (`g_mapTileID`), so an animation `STOP` can
    /// restore it. Snapshotted by `createLandscape`.
    public var mapBaseTileID = [UInt16](repeating: 0, count: 64 * 64)

    /// Set whenever an animation changes a map ground tile, so a renderer knows to re-blit.
    public var mapDirty = false

    public init(random256Seed: UInt32 = 0, randomLCGSeed: UInt16 = 0) {
        units = Array(repeating: Unit(), count: Pool.unitIndexMax)
        structures = Array(repeating: Structure(), count: Pool.structureIndexMaxHard)
        houses = Array(repeating: House(), count: Pool.houseIndexMax)
        teams = Array(repeating: Team(), count: Pool.teamIndexMax)
        map = Array(repeating: MapTile(), count: 64 * 64)
        random256 = Random256(seed: random256Seed)
        randomLCG = RandomLCG(seed: randomLCGSeed)
    }
}
