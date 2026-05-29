import DuneIIContracts

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

    /// OpenDUNE's `g_validateStrictIfZero`: 0 = strict validation (normal play); non-zero bypasses the
    /// allocate / placement guards (used while loading a save or scenario).
    public var validateStrictIfZero: UInt16 = 0

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
