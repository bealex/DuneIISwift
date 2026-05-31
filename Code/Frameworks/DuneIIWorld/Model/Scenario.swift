/// The scenario-level mission state — a port of the win/lose + score fields of OpenDUNE's `g_scenario`
/// (`src/scenario.h`). Loaded from the `[BASIC]` section; the score tallies are bumped as units/structures
/// die and spice is refined.
public struct Scenario: Sendable, Equatable {
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

    public init() {}
}

/// Whether the human player's level is still in progress, won, or lost (`GameLoop_IsLevelFinished/Won`).
public enum GameEndState: UInt8, Sendable, Equatable { case playing, won, lost }
