/// The scenario-level mission state — a port of the win/lose + score fields of OpenDUNE's `g_scenario`
/// (`src/scenario.h`). Loaded from the `[BASIC]` section; the score tallies are bumped as units/structures
/// die and spice is refined.
public struct Scenario: Sendable, Equatable, Codable {
    /// `[BASIC] WinFlags` — which conditions END the level (`GameLoop_IsLevelFinished`): bit 0 = no enemy
    /// structures remain, bit 1 = no friendly structures remain, bit 2 = the player reached the spice quota,
    /// bit 3 = timeout (unused in 1.07 — `s_tickGameTimeout` is never set).
    public var winFlags: UInt16 = 0
    /// `[BASIC] LoseFlags` — once the level ends, which conditions mean the player **won** (`GameLoop_IsLevelWon`).
    public var loseFlags: UInt16 = 0

    // Score / kill tallies (the `g_scenario` counters).
    public var killedAllied: UInt16 = 0
    public var killedEnemy: UInt16 = 0
    public var destroyedAllied: UInt16 = 0
    public var destroyedEnemy: UInt16 = 0
    public var harvestedAllied: UInt32 = 0
    public var harvestedEnemy: UInt32 = 0
    /// Running mission score (`g_scenario.score`, `uint16` — wraps): up for an enemy kill/destroy, down for
    /// a friendly loss, by `max(buildCredits/100, 1)`.
    public var score: UInt16 = 0

    /// `[REINFORCEMENTS]` — the timed-spawn table (`g_scenario.reinforcement[16]`). A loaded slot
    /// counts down `timeLeft` (every 600 ticks, in the house loop); at zero it deploys `unitType` for
    /// `houseID` at `locationID`. See `Reinforcement`.
    public var reinforcements = [ Reinforcement ](repeating: Reinforcement(), count: 16)

    /// `[MAP] Field` — explicit hand-placed spice-field tiles (packed). The original detonates a spice bloom
    /// at each (`Scenario_Load_Map_Field` → `Map_Bloom_ExplodeSpice`) **at load**; we can't reach the sim's
    /// `Map_Bloom_ExplodeSpice` from the World loader, so we stash the tiles here and the Simulation fills them
    /// once, before its first tick (`Simulation.applyScenarioSpiceFields`). Consumed (cleared) on apply.
    public var spiceFields: [UInt16] = []

    public init() {}
}

/// One `[REINFORCEMENTS]` entry (`Reinforcement`, `scenario.h`). 1.07 stores a created off-map `unitID`;
/// we instead keep the *recipe* (`unitType`/`houseID`) and create the unit at deploy time — observably
/// identical (the unit appears at `locationID` after `timeBetween` decrements), modulo pre-deploy pool
/// occupancy. An empty slot has `unitType == 0xFF` (`UNIT_INVALID`).
public struct Reinforcement: Sendable, Equatable, Codable {
    public var unitType: UInt8 = 0xFF
    public var houseID: UInt8 = 0xFF
    /// 0-3 = N/E/S/W map edge (`Unit_SetPosition`), 4-7 = AIR/VISIBLE/ENEMYBASE/HOMEBASE (carryall drop).
    public var locationID: UInt8 = 0
    /// Decrements once per reinforcement cursor fire (600 ticks); deploys at 0. Seeded to `timeBetween`.
    public var timeLeft: UInt16 = 0
    public var timeBetween: UInt16 = 0
    /// `[REINFORCEMENTS]` trailing `+`. **Pinned `false`** — 1.07 (non-enhanced, our oracle) has a
    /// parse bug that always clears it, so every reinforcement fires exactly once.
    public var repeats: Bool = false

    public init() {}
    public var isEmpty: Bool { unitType == 0xFF }
}

/// Whether the human player's level is still in progress, won, or lost (`GameLoop_IsLevelFinished/Won`).
public enum GameEndState: UInt8, Sendable, Equatable, Codable { case playing, won, lost }
