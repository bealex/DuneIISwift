import DuneIIContracts
import DuneIIFormats

/// "Next-due" tick timestamps for each `GameLoop_Unit` sub-activity (OpenDUNE's `s_tickUnit*`).
/// An activity fires when its cursor is `<= timerGame`, then advances by its interval.
public struct UnitTickCursors: Sendable, Equatable, Codable {
    public var movement: UInt32 = 0
    public var rotation: UInt32 = 0
    public var blinking: UInt32 = 0
    public var unknown4: UInt32 = 0
    public var script: UInt32 = 0
    public var unknown5: UInt32 = 0
    public var deviation: UInt32 = 0
    public init() {}
}

/// "Next-due" tick timestamps for each `GameLoop_Structure` sub-activity (OpenDUNE's `s_tickStructure*`).
/// An activity fires when its cursor is `<= timerGame`, then advances by its interval. Only `script` drives
/// logic today; `degrade`/`structure`/`palace` advance their cursors but their bodies are still seams
/// (the campaign-degrade, BUILD/REPAIR/factory production, and palace special-weapon slices).
public struct StructureTickCursors: Sendable, Equatable, Codable {
    public var degrade: UInt32 = 0
    public var structure: UInt32 = 0
    public var script: UInt32 = 0
    public var palace: UInt32 = 0
    public init() {}
}

/// "Next-due" tick timestamps for each `GameLoop_House` sub-activity (OpenDUNE's `s_tickHouse*`). Live
/// bodies: `house` (economy + `House_EnsureHarvesterAvailable` + harvester-incoming spawn), `powerMaintenance`
/// (upkeep), `starport` (frigate delivery), `starportAvailability` (stock bump). Still seams: `reinforcement`
/// (needs `[REINFORCEMENTS]` scenario data) and `missileCountdown` (the palace house-missile, a slice-7 subsystem).
public struct HouseTickCursors: Sendable, Equatable, Codable {
    public var house: UInt32 = 0
    public var powerMaintenance: UInt32 = 0
    public var starport: UInt32 = 0
    public var reinforcement: UInt32 = 0
    public var missileCountdown: UInt32 = 0
    public var starportAvailability: UInt32 = 0
    public init() {}
}

/// The single owned aggregate of all mutable simulation state (engine principle 4). A port of the
/// OpenDUNE globals: the object pools (`g_unitArray`/`g_structureArray`/`g_houseArray`/`g_teamArray`
/// + their find arrays), the `g_map[64*64]` grid, both RNGs, and the two tick clocks.
///
/// It is a value type, so copying a `GameState` is a full snapshot. Code mutates objects in place via
/// their pool index (e.g. `state.units[i].o.hitpoints = …`). See `Documentation/Architecture/DataModel.md`.
public struct GameState: Sendable, Codable {
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

    /// Per-subsystem "next-due" tick cursors for `GameLoop_Structure` (OpenDUNE's `s_tickStructure*`).
    public var structureTick = StructureTickCursors()

    /// Per-subsystem "next-due" tick cursors for `GameLoop_House` (OpenDUNE's `s_tickHouse*`).
    public var houseTick = HouseTickCursors()

    /// `GameLoop_Team`'s single next-due cursor (OpenDUNE's `s_tickTeamGameLoop`). The team loop fires when
    /// `teamLoopTick <= timerGame`, then re-arms to `timerGame + (Random256() & 7) + 5` (a 5…12-tick period).
    public var teamLoopTick: UInt32 = 0

    /// `g_playerCreditsNoSilo`: how much credit the player can hold without a spice silo (the starting
    /// allowance + what silos add). The credit clamp uses `max(creditsStorage, playerCreditsNoSilo)` for the
    /// player. Managed at scenario load / on building a silo (a seam for now); 0 ⇒ clamp to storage.
    public var playerCreditsNoSilo: UInt16 = 0

    /// OpenDUNE's `g_validateStrictIfZero`: 0 = strict validation (normal play); non-zero bypasses the
    /// allocate / placement guards (used while loading a save or scenario).
    public var validateStrictIfZero: UInt16 = 0

    /// Scenario map scale (0 = 62×62, 1 = 32×32, 2 = 21×21). OpenDUNE's `g_scenario.mapScale`; indexes
    /// `MapInfo.scales`. Set by scenario loading (not yet ported).
    public var mapScale: UInt8 = 0

    /// The local player's house. OpenDUNE's `g_playerHouseID`; set by scenario loading (not yet ported).
    public var playerHouseID: UInt8 = 0

    /// **Debug/test only.** When true, the AI gets a crude fog of war: player-owned objects are no longer
    /// auto-revealed to every house (`seenByHouses = 0xFF`) on placement — instead an AI house only learns
    /// of the player's base/army the first time the player makes contact with it. Default `false` keeps the
    /// exact stock Dune II 1.07 behaviour (and so is golden/RNG neutral). See `Architecture/AIFogOfWar.md`.
    public var aiFogOfWar: Bool = false

    /// `aiFogOfWar` companion: bitmask of AI houses that have made contact with the player (and so now see
    /// the whole player base). Always 0 with the flag off.
    public var housesFoundPlayer: UInt8 = 0

    /// The active campaign (mission) number, 1…9. OpenDUNE's `g_campaignID`. Feeds several deterministic
    /// economy formulas faithfully — the structure-degrade gate (`> 1`), the AI build-speed cap
    /// (`campaignID*20+95`), the repair heal amount (`>= 3` → +5), and `Structure_IsUpgradable`. Defaults to
    /// the first campaign; scenario loading will set it. (Replaces the earlier "campaigns aren't modeled" pins.)
    public var campaignID: UInt8 = 1

    /// The mission's win/lose flags + score tallies (`g_scenario`), loaded from `[BASIC]`.
    public var scenario = Scenario()
    /// Whether the human player's level is in progress, won, or lost (`GameLoop_IsLevelFinished/Won`).
    public var gameEndState: GameEndState = .playing
    /// `g_tickScenarioStart`: the `timerGame` the scenario began at (the win check needs ≥7200 ticks played).
    public var tickScenarioStart: UInt32 = 0

    /// The map viewport's top-left packed tile (OpenDUNE's `g_viewportPosition`). Render state, but it
    /// feeds the deterministic sim: `GameLoop_Unit` throttles an off-viewport unit's script to 3
    /// opcodes/tick (`Map_IsPositionInViewport`). Set by the host (camera) / the parity harness.
    public var viewportPosition: UInt16 = 0

    /// The minimap (radar) top-left packed tile (OpenDUNE's `g_minimapPosition`). Feeds the "Visible"
    /// reinforcement spawn location (`Map_FindLocationTile` case 5).
    public var minimapPosition: UInt16 = 0

    /// `g_starportAvailable[UNIT_MAX]`: per-unit-type starport stock. -1 = sold out (becomes 1 again),
    /// 0 = never available, 1…10 = in stock. `GameLoop_House`'s starport-availability tick randomly bumps
    /// an already-available type. Sized to the unit-type table (0…26).
    public var starportAvailable: [Int16] = Array(repeating: 0, count: 27)

    /// Runtime tile-id bases derived from `ICON.MAP` (`Sprites_Init`); populated at load. Anchors
    /// `Map_GetLandscapeType` etc.
    public var tileIDs = TileIDs()

    /// The decoded `ICON.MAP`, kept for the animation engine's icon-group tile lookups. Set at load.
    public var iconMap: IconMap?

    /// Active structure animations (`g_animations`, 112 slots).
    public var animations = [Animation](repeating: Animation(), count: 112)

    /// `s_animationTimer`: the next tick the animation pass needs to run.
    public var animationTimer: UInt32 = 0

    /// Active explosions (`g_explosions`, `EXPLOSION_MAX` = 32 slots) — the short visual sprite
    /// animations for impacts/deaths/destruction. Started by `Map_MakeExplosion`; ticked (gated) by
    /// `explosionTick()`. See `Documentation/Algorithms/Explosion.md`.
    public var explosions = [Explosion](repeating: Explosion(), count: 32)

    /// `s_explosionTimer`: the next tick the explosion pass needs to run.
    public var explosionTimer: UInt32 = 0

    /// Sounds the sim asked to play this tick (the `sim → audio` seam, OpenDUNE's inline
    /// `Voice_PlayAtTile`/`Sound_Output_Feedback` sites). The host drains + plays them after each tick; the
    /// loop clears it at the start of every tick, so a non-draining (golden) run never accumulates.
    /// `SoundID` carries the OpenDUNE voice id (e.g. a unit's `bulletSound`); the host maps it to a VOC.
    public var soundEvents: [SoundEvent] = []

    /// Packed tiles where an explosion's VM hit a still-live spice bloom this tick (`Explosion_Func_BloomExplosion`,
    /// `explosion.c:157`). The World-layer explosion VM only records the tile; the Simulation drains this after
    /// `explosionTick` and runs `Map_Bloom_ExplodeSpice` (a Simulation primitive — spice-fill + tremor). Transient:
    /// only populated while explosions tick (the visual apps), so a golden/parity run never accumulates.
    public var pendingBloomDetonations: [UInt16] = []

    /// Queue a sound at a world position (`Voice_PlayAtTile`, `sound.c:134`). Ignores out-of-range ids and
    /// the `0xFFFF` "no sound" sentinel. RNG-free, so it doesn't perturb the golden/parity path.
    public mutating func emitSound(_ voiceID: Int, at position: Tile32) {
        guard voiceID >= 0, voiceID < 120 else { return }
        soundEvents.append(SoundEvent(sound: SoundID(voiceID), positionX: Int(position.x), positionY: Int(position.y)))
    }

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
