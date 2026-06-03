import CoreGraphics
import DuneIIAudio
import DuneIIContracts
import DuneIIFormats
import DuneIIInput
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import Foundation

/// The client's central state, shared by the map window + every tool window. Owns the live `Simulation`,
/// the input controller (selection/orders), the camera `Viewport` (scroll/zoom), the player house, the
/// debug toggles, and the derived per-frame info the panels read (selection, economy, minimap, last frame).
/// `@Observable`, so the SwiftUI windows update reactively.
@MainActor
@Observable
public final class GameModel {
    public let assets: AssetStore
    @ObservationIgnored let audio = EngineAudioSink()
    /// In-game music (host-side presentation — never touches the sim). Maps OpenDUNE's `g_table_musics`
    /// selection to the music assets in `Resources/Audio/Music/` — either the Westwood `.ADL` files
    /// synthesised on an emulated OPL3 chip (authentic AdLib FM, the default) or the extracted MIDI songs
    /// through `AVMIDIPlayer` + a SoundFont/DLS bank. The backend is switchable live (Settings).
    @ObservationIgnored let music = MusicDirector(musicDirectory: GameModel.musicURL(),
                                                  soundBank: GameModel.soundBankURL(),
                                                  backend: GameModel.savedMusicBackend())
    /// Master music toggle — also the neutrality switch for goldens (off ⇒ music never plays, sim untouched).
    var musicEnabled = true { didSet { music.enabled = musicEnabled } }
    /// Synthesis backend for the music (AdLib FM vs MIDI). Applied live and persisted across launches.
    var musicBackend: MusicBackend = GameModel.savedMusicBackend() {
        didSet {
            music.backend = musicBackend
            UserDefaults.standard.set(musicBackend.rawValue, forKey: "musicBackend")
        }
    }
    /// Master sound-effects toggle (Settings). Off ⇒ no SFX play; the sim is untouched (presentation only).
    var soundEnabled = true { didSet { audio.enabled = soundEnabled } }
    @ObservationIgnored public var scene: GameScene!

    public private(set) var currentScenario: String?
    public private(set) var simulation: Simulation?
    @ObservationIgnored private var unitScript: ScriptInfo?
    @ObservationIgnored private var structureScript: ScriptInfo?
    @ObservationIgnored private var controller = InputController(mapWidth: 64)

    /// Camera. The scene applies it; the minimap reads it.
    var viewport = Viewport()
    /// The map view's pixel size in points (the scene keeps this current for scroll/zoom clamping).
    @ObservationIgnored var viewSize = CGSize(width: 1024, height: 768)

    private(set) var playerHouse: HouseID = .atreides

    // Debug toggles (the Debug window binds these; the scene/economy/fog read them).
    var showFog = false { didSet { scene?.applyFog(); if let lastFrame { refreshMinimapBase(lastFrame) } } }
    /// Debug: give the AI a fog of war so it only attacks after the player makes contact (instead of
    /// knowing the base from turn one). Applied to the live sim and to every scenario (re)load. Best set
    /// before loading a scenario — toggling mid-game only affects objects placed/sighted afterwards.
    var aiFogOfWar = false { didSet {
        simulation?.state.aiFogOfWar = aiFogOfWar
        // Re-hide (or re-reveal) the already-placed base/army so toggling mid-game or after a scenario load
        // takes effect immediately — otherwise objects keep the visibility they were placed with.
        simulation?.state.reapplyPlayerVisibility()
    } }
    /// Whether the per-house unit limit (the scenario's `MaxUnit`) is enforced. On (default) = follow the
    /// limit faithfully; off = build past it. Applied to the live sim and to every scenario (re)load.
    var enforceUnitLimit = true { didSet { simulation?.state.enforceUnitLimit = enforceUnitLimit } }
    /// Play indefinitely: skip the win/lose evaluation so the game never ends. Applied to the live sim and to
    /// every scenario (re)load. Turning it on also clears any already-latched outcome (and dismisses the
    /// banner) so a finished game can resume.
    var playIndefinitely = false { didSet {
        simulation?.state.disableLevelEnd = playIndefinitely
        if playIndefinitely, simulation?.state.gameEndState != .playing {
            simulation?.state.gameEndState = .playing
            gameEnd = .playing
        }
    } }
    var showAllEconomies = false
    var showHealthOverlay = true   // health/state bars over units + buildings are on by default (a normal HUD element)
    /// Debug: force the minimap on regardless of radar availability. Off (default) ⇒ the minimap obeys the
    /// player's radar (`radarActive`) — blank until an outpost + power bring it online, as in Dune II.
    var forceMinimap = false
    /// The campaign (mission) level 1…9 — OpenDUNE's `g_campaignID`, which gates build availability (the
    /// construction-yard `availableCampaign` check) and the upgrade chain. Our scenario `.INI`s don't carry
    /// it, so it's derived from the loaded scenario's mission number (`ScenarioID.campaign`) and set on load.
    private(set) var campaignLevel = 1

    /// The install's scenarios, parsed into house / mission / campaign for the picker (it groups by house,
    /// then campaign level). Stable after load, so recomputing per access is cheap.
    var scenarioCatalog: [ScenarioID] {
        assets.scenarioNames.compactMap(ScenarioID.init(fileName:)).sorted { $0.mission < $1.mission }
    }

    /// A friendly label for the current scenario (house + mission), for the toolbar button.
    public var scenarioTitle: String {
        guard let name = currentScenario, let s = ScenarioID(fileName: name) else { return "Scenario" }
        return "\(s.house.displayName) · Mission \(s.mission)"
    }

    // Radar / minimap state (read by `MinimapView`).
    /// The player house's radar is active (outpost built + powered) — the minimap shows live content.
    private(set) var radarActive = false
    /// The decoded STATIC.WSA "tuning" frames, played on each radar on/off transition. Loaded once.
    @ObservationIgnored private(set) var radarStaticFrames: [CGImage] = []
    /// The static frame currently showing during a transition (`nil` ⇒ no transition in progress).
    private(set) var radarStaticFrameIndex: Int?
    @ObservationIgnored private var radarStaticForward = true   // play forward (on) or backward (off)
    @ObservationIgnored private var radarStaticTick = 0         // sub-frame counter (a few render frames per WSA frame)

    /// Wall-clock speed multiplier (0.5×…4×). The scene paces sim ticks against real time × this — see
    /// `GameScene.update`. 1× ≈ the base 60-ticks/second cadence (one tick per drawn frame at 60 fps).
    public var gameSpeed: Double = 1
    /// Freeze the simulation (the two-clock pause — `Simulation.tick` no-ops while `state.paused`). The
    /// camera, selection, and orders still work; only game time stops. The **effective** pause: the player's
    /// own pause (`userPaused`) OR any open UI surface (`uiPauseCount` — a save/load dialog, the options or
    /// mentat popover). Read-only outside; drive it via `togglePause`/`beginUIPause`/`endUIPause`.
    public private(set) var paused = false { didSet {
        guard paused != oldValue else { return }
        simulation?.state.paused = paused
        paused ? music.pause() : music.resume()
    } }
    /// The player's manual pause (space bar / game over) — what the game returns to when every transient UI
    /// surface closes.
    @ObservationIgnored private var userPaused = false
    /// How many UI surfaces currently want the game frozen (balanced `beginUIPause`/`endUIPause`); the game is
    /// paused while any are open, then resumes to `userPaused`.
    @ObservationIgnored private var uiPauseCount = 0
    /// Recompute the effective pause from the player's pause + open UI surfaces.
    private func applyPause() { paused = userPaused || uiPauseCount > 0 }
    /// The latched level outcome (`GameLoop_IsLevelFinished`). `playing` until a Win/Lose condition is met,
    /// then `won`/`lost`; the client shows a banner + pauses. Reset to `playing` on each scenario/save load.
    private(set) var gameEnd: GameEndState = .playing
    /// The end-of-game banner text, or `nil` while playing.
    public var outcomeText: String? { switch gameEnd { case .won: "Victory"; case .lost: "Defeat"; case .playing: nil } }

    // Derived per-frame info for the tool windows.
    private(set) var selection: SelectionInfo?
    private(set) var pendingOrder: OrderKind?
    private(set) var economy: [HouseEconomy] = []
    /// A bare tile the player left-clicked to inspect (no unit/structure there). Shown in the inspector when
    /// nothing is selected. `inspectedTile` is the live tile coords; `tileInfo` is its derived parameters.
    @ObservationIgnored private var inspectedTile: (x: Int, y: Int)?
    private(set) var tileInfo: TileInfo?
    /// A transient player hint banner (construction complete / low power / no funds), auto-cleared after a
    /// few seconds. Derived each frame from the player's economy + factories — no new sim events needed.
    public private(set) var notice: String?
    @ObservationIgnored private var noticeFrames = 0
    @ObservationIgnored private var wasLowPower = false
    @ObservationIgnored private var readyFactories: Set<Int> = []
    /// Durations (seconds) of the registered death-announcement voice fragments, for sequencing them.
    @ObservationIgnored private var speechDuration: [SoundID: TimeInterval] = [:]
    /// True while a spoken death announcement is playing — rate-limits so battles don't pile up speech.
    @ObservationIgnored private var speaking = false

    // Build-GUI derived state (refreshed for the selected player-owned factory).
    /// The selected factory's **full** build menu (every item, locked ones tagged with their blockers) so the
    /// panel can grey-out unavailable items with a "what's missing" tooltip.
    private(set) var buildOptions: [BuildOption] = []
    private(set) var buildProgress: BuildState?
    private(set) var isFactorySelected = false
    private(set) var playerCredits = 0
    /// Repair/upgrade availability for the selected player structure (nil = not a player structure).
    private(set) var structureActions: StructureActions?
    /// Whether the current selection is a player-owned starport (so the sidebar shows the CHOAM order panel).
    private(set) var isStarportSelected = false
    /// Orderable units for a selected player starport (CHOAM buy): each carries its rolled price + live stock.
    private(set) var starportStock: [StarportItem] = []
    /// The staged CHOAM order ("cart"): unit type → quantity. Built up with `cartAdd`/`cartRemove`, then
    /// dispatched as a batch by `sendStarportOrder` (or discarded by `clearStarportCart`). Charged on send.
    private(set) var starportCart: [UInt16: Int] = [:]
    /// The player house's in-flight starport delivery (frigate-arrival countdown), or nil if none is pending.
    private(set) var starportDelivery: StarportDelivery?
    /// The starport slot whose CHOAM prices are currently rolled (so the per-tick refresh re-uses them
    /// instead of re-rolling), and the prices by unit type.
    @ObservationIgnored private var pricedStarport: Int?
    @ObservationIgnored private var starportPriceByType: [Int: UInt16] = [:]
    /// Super-weapon state for a selected player **palace** (nil if the selection isn't a player palace).
    private(set) var superWeapon: SuperWeaponState?
    /// While non-nil, the palace slot awaiting a death-hand **target** click (the human missile launch).
    private(set) var missileTargeting: Int?
    /// Active structure-placement mode: a finished construction-yard product awaiting a map click.
    private(set) var placement: PlacementState?
    /// Build/place/cancel commands queued from the UI, applied next `advance()` (alongside unit orders).
    @ObservationIgnored private var pendingCommands: [Command] = []
    /// The latest frame — observed, so the minimap redraws each tick (units/viewport move).
    private(set) var lastFrame: FrameInfo?
    /// Throttles the steady-state HUD derivations (economy/credits/build/structure-actions/tile-info/hints)
    /// to ~10 Hz instead of the display rate, the bulk of the per-frame SwiftUI re-layout cost. Interaction
    /// (a selection/order change) overrides it so the panels still respond instantly. ~6 of the ~60 display
    /// frames per second; presentation-only, never gates sim state.
    @ObservationIgnored private var hudThrottle = FrameThrottle(every: 6)
    @ObservationIgnored private(set) var minimapBase: CGImage?
    /// The decoded terrain source for the minimap base, built once (the asset tiles don't change).
    @ObservationIgnored private var minimapSource: DecodedSpriteSource?
    /// A cheap hash of the terrain tiles the current `minimapBase` was built from, so it's rebuilt only when
    /// the map actually changes (structures baking into the ground, walls, craters, spice) — not every tick.
    @ObservationIgnored private var minimapTilesHash = 0

    public init(assets: AssetStore) {
        self.assets = assets
        scene = GameScene(model: self)
        setupAudio()
        if let first = assets.scenarioNames.first { load(first) }
    }

    // MARK: - Loading

    /// The canonical late-game CHOAM stock (the standard install's `SCEN?020` `[CHOAM]` list), seeded on a
    /// scenario that carries no `[CHOAM]` section of its own so a built starport is always orderable.
    private static let defaultChoamStock: [(UnitType, Int16)] = [
        (.trike, 5), (.quad, 5), (.tank, 5), (.siegeTank, 4), (.launcher, 4),
        (.harvester, 2), (.mcv, 2), (.carryall, 2), (.ornithopter, 3),
    ]

    func load(_ scenarioName: String) {
        guard let ini = assets.scenarioINI(scenarioName), let iconMap = assets.iconMap else { return }
        unitScript = assets.data("UNIT.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
        structureScript = assets.data("BUILD.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }

        var state = GameState()
        state.aiFogOfWar = aiFogOfWar   // before unit placement, so the player units honour the AI-fog mask
        state.enforceUnitLimit = enforceUnitLimit
        // Don't pin the AI houses active at load (that's a parity-harness shortcut). Like OpenDUNE's real game,
        // each AI house wakes (`isAIActive`) only when it first makes contact with an enemy — driven by our
        // fog/visibility path (`unitUpdateMap`/`mapUnveilTile` → `unitHouseUnitCountAdd`). Pinning it on made the
        // AI ramp its economy + launch house missiles from tick 0, so it assaulted the player base far too early.
        state.loadScenario(ini: ini, iconMap: iconMap, activateTeamHousesAI: false)
        // The mission level (gates build availability + the upgrade chain) — derived from the scenario's file
        // number, since the `.INI` itself doesn't carry it. SCENA001 ⇒ campaign 1, SCENx020+ ⇒ campaign 8, etc.
        campaignLevel = ScenarioID(fileName: scenarioName)?.campaign ?? 1
        state.campaignID = UInt8(clamping: campaignLevel)
        // Activate every house; keep each one's scenario unit cap (`[HOUSES] MaxUnit`), defaulting houses with
        // no `[HOUSES]` entry to the Dune II default (39). The `enforceUnitLimit` toggle decides whether the
        // cap actually bites — so "follow the unit limit" uses the real scenario limit, not a pinned 1000.
        for h in 0 ..< 6 {
            _ = state.houseAllocate(index: UInt8(h))
            if state.houses[h].unitCountMax == 0 { state.houses[h].unitCountMax = 39 }
        }
        playerHouse = AssetStore.playerHouse(in: ini)
            ?? state.houses.first(where: { $0.flags.contains(.used) }).flatMap { HouseID(rawValue: Int($0.index)) }
            ?? .atreides
        state.playerHouseID = UInt8(playerHouse.rawValue)
        // Mark the player's house human (as a real Brain=Human load does) so the human-only gates behave —
        // chiefly the palace special-weapon auto-fire (`!human && isAIActive`), which otherwise launches the
        // player's own house missile on the palace's first tick. Set on the *chosen* player house, since it can
        // differ from any Brain=Human the loader saw (the fallbacks above).
        state.houses[Int(playerHouse.rawValue)].flags.insert(.human)
        // Arm placed factories' upgrade state (the loader hand-rolls structure init and skips it) — now that
        // campaignID + playerHouseID are set, both of which gate `structureIsUpgradable`. Without this a loaded
        // construction yard never offers the Upgrade option. Mirrors `Structure_Create` at scenario load.
        state.armPlacedFactoryUpgrades()
        // Verification affordance: a real late-game scenario seeds the starport's CHOAM stock from its `[CHOAM]`
        // section, but early maps carry none — so a starport built there (the campaign-level picker can unlock
        // one early) has an empty order list. Seed the canonical CHOAM set when the scenario provided nothing,
        // so CHOAM ordering is always exercisable. Client-only; the parity `loadScenario` path is untouched.
        if state.starportAvailable.allSatisfy({ $0 == 0 }) {
            for (type, stock) in Self.defaultChoamStock where type.rawValue < state.starportAvailable.count {
                state.starportAvailable[type.rawValue] = stock
            }
        }
        state.viewportPosition = Tile32.packXY(x: 32, y: 32)

        if let unitScript {
            let setup = UnitActions()
            for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
                setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: unitScript, in: &state)
                state.unitUpdateMap(1, slot)
            }
        }

        finishLoad(state: state, scenarioName: scenarioName)
    }

    /// Build the live `Simulation` from a ready `GameState` (a freshly-loaded scenario or a restored save) and
    /// set up the scene, camera, and minimap. Shared by `load` and `loadGame`.
    private func finishLoad(state: GameState, scenarioName: String?) {
        var state = state
        state.disableLevelEnd = playIndefinitely   // the live "play indefinitely" preference wins on every load
        let sim = Simulation(state: state, scriptInfo: unitScript, structureScriptInfo: structureScript,
                             tickExplosions: true, tickAnimations: true)
        simulation = sim
        currentScenario = scenarioName
        playerHouse = HouseID(rawValue: Int(state.playerHouseID)) ?? .atreides
        registerHouseVoices()      // the player-house announcement voices (the prefix can change per scenario)
        userPaused = state.paused  // fresh scenario ⇒ false; a restored save ⇒ its saved pause
        applyPause()               // keep any open UI surface's pause (e.g. the load dialog) in effect
        gameEnd = state.gameEndState
        // Reset the transient hint state so the new base doesn't false-fire build-complete / under-attack.
        wasLowPower = false; readyFactories = []
        notice = nil; noticeFrames = 0
        controller.deselect()
        scene.load(simulation: sim, assets: assets)
        let frame = sim.makeFrameInfo()
        lastFrame = frame
        // Clamp the camera to the scenario's playable rectangle (so it can't scroll onto the black border)
        // and start centred on it. The renderer blacks the border out independently (`FrameComposer`).
        viewport = Viewport()
        let a = frame.mapArea
        viewport.area = CGRect(x: Double(a.minX) * Viewport.tilePx, y: Double(a.minY) * Viewport.tilePx,
                               width: Double(a.width) * Viewport.tilePx, height: Double(a.height) * Viewport.tilePx)
        viewport.center(onWorldX: viewport.area.midX, worldY: viewport.area.midY, viewSize: viewSize)
        minimapSource = nil; minimapTilesHash = 0   // fresh scenario → rebuild the base from its tiles
        refreshMinimapBase(frame)
        if radarStaticFrames.isEmpty { radarStaticFrames = Minimap.radarStaticFrames(assets: assets) }   // STATIC.WSA, once
        radarActive = frame.houses.first { $0.id == playerHouse }?.radarActivated ?? false
        radarStaticFrameIndex = nil
        refreshDerived(frame)
        music.startInGame()   // a random in-mission map theme (musicID 8–15), rolling into the next at its end
    }

    /// Where the extracted MIDI songs live — the app bundle's `Audio/Music/` when packaged, else the repo's
    /// `Resources/` relative to `Code/` (how `swift run duneii` is launched), mirroring `App.installURL()`.
    private static func musicURL() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Audio/Music"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: "../Resources/Audio/Music")
    }

    /// The persisted music backend, defaulting to authentic AdLib FM (OPL3). Read once at init.
    private static func savedMusicBackend() -> MusicBackend {
        (UserDefaults.standard.string(forKey: "musicBackend")).flatMap(MusicBackend.init(rawValue:)) ?? .adlib
    }

    /// Optional SoundFont for the MIDI synth: a bundled/repo `Audio/music.sf2` if present, else `nil` ⇒ the
    /// system's built-in General-MIDI DLS bank. Pluggable so a better bank can be dropped in later.
    private static func soundBankURL() -> URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Audio/music.sf2"),
                          URL(fileURLWithPath: "../Resources/Audio/music.sf2")].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Save the current game to `url` — our versioned `SaveGame` (the whole `GameState`, a bit-identical
    /// deterministic resume point). Returns false on failure.
    @discardableResult
    public func saveGame(to url: URL) -> Bool {
        guard let sim = simulation, let data = try? SaveGame.save(sim.state) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }

    /// Restore a saved game from `url` (`SaveGame.load`) and resume it. Reloads the EMC scripts (the same
    /// programs) so the sim can run; the rest of the state comes from the save.
    @discardableResult
    public func loadGame(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let state = try? SaveGame.load(data) else { return false }
        unitScript = assets.data("UNIT.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
        structureScript = assets.data("BUILD.EMC").flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
        finishLoad(state: state, scenarioName: "Saved game")
        return true
    }

    private func setupAudio() {
        if let s = assets.voc("CLICK.VOC") { audio.register(.select, sampleRate: s.sampleRate, pcm8: s.samples) }
        // The unit "speaks" voices (`g_table_voices` 17–22) — select/order acknowledgements.
        let unitVoices: [(SoundID, String)] = [
            (.acknowledge, "AFFIRM.VOC"), (.report1, "REPORT1.VOC"), (.report2, "REPORT2.VOC"),
            (.report3, "REPORT3.VOC"), (.moveOut, "MOVEOUT.VOC"), (.overOut, "OVEROUT.VOC"),
        ]
        for (id, voc) in unitVoices {
            if let s = assets.voc(voc) { audio.register(id, sampleRate: s.sampleRate, pcm8: s.samples) }
        }
        // The sim's combat sound effects: register each VOC under its OpenDUNE voice id (the SoundEvent id).
        for (voiceID, voc) in VoiceTable.registrations {
            if let s = assets.voc(voc) { audio.register(SoundID(voiceID), sampleRate: s.sampleRate, pcm8: s.samples) }
        }
        audio.start()
    }

    /// Register the player house's spoken **announcement** voices (the `%c`-prefixed VOCs, `%c` = the house
    /// letter: `HCONST.VOC`/`AWARNING.VOC`/…). Called on each load since the player house can change.
    private func registerHouseVoices() {
        let prefix = String(Character(UnicodeScalar(UInt8(truncatingIfNeeded: HouseInfo[playerHouse].prefixChar))))
        let voices: [(SoundID, String)] = [
            (.houseConstruct, "\(prefix)CONST.VOC"), (.houseUnderAttack, "\(prefix)WARNING.VOC"),
        ]
        for (id, voc) in voices where assets.voc(voc) != nil {
            let s = assets.voc(voc)!
            audio.register(id, sampleRate: s.sampleRate, pcm8: s.samples)
        }
        // The spoken feedback-announcement fragments ("<house>ENEMY/UNIT/DESTROY/WARNING/…") — registered
        // under their FeedbackVoice ids with their durations, so `playFeedback` can chain a sequence in order.
        // Strip the leading load-class marker (`?`/`+`/`-`/`/`) before substituting `%c` → the house letter.
        speechDuration.removeAll(keepingCapacity: true)
        for (voice, template) in FeedbackVoice.fragments {
            var name = template
            if let f = name.first, "?+-/".contains(f) { name.removeFirst() }
            let voc = name.replacingOccurrences(of: "%c", with: prefix)
            guard let s = assets.voc(voc) else { continue }
            let id = FeedbackVoice.id(voice)
            audio.register(id, sampleRate: s.sampleRate, pcm8: s.samples)
            speechDuration[id] = s.sampleRate > 0 ? Double(s.samples.count) / Double(s.sampleRate) : 0
        }
    }

    /// Play a spoken `Sound_Output_Feedback` announcement — its fragment sequence, each clip after the
    /// previous one finishes. Threat feedbacks switch to battle music + show a banner first (always), then the
    /// speech is rate-limited to one announcement at a time (`speaking`) so a busy battle doesn't pile up
    /// overlapping voices (mirrors OpenDUNE's single-speech / priority behaviour).
    private func playFeedback(_ feedback: UInt16) {
        guard let seq = FeedbackVoice.sequences[feedback] else { return }
        if FeedbackVoice.battleMusic.contains(feedback) { music.enterBattle() }
        if let text = FeedbackVoice.notice[feedback] { postNotice(text) }
        guard !speaking else { return }
        let ids = seq.map { FeedbackVoice.id($0) }.filter { speechDuration[$0] != nil }
        guard !ids.isEmpty else { return }
        speaking = true
        Task { @MainActor [weak self] in
            for id in ids {
                guard let self else { return }
                self.audio.play(id)
                try? await Task.sleep(for: .seconds(self.speechDuration[id] ?? 0.4))
            }
            self?.speaking = false
        }
    }

    /// The "unit reports in" voice on selecting a player unit — REPORT1 (foot) / REPORT2 (vehicle), faithful
    /// to `unit.c:1730`. A structure selection keeps the plain CLICK (`.select`).
    private func playSelectVoice(unitSlot: Int?) {
        guard let slot = unitSlot else { audio.play(.select); return }
        audio.play(isFootUnit(slot) ? .report1 : .report2)
    }

    /// The order-acknowledge voice (`viewport.c:182`): a **foot** unit speaks the action's voice (move →
    /// MOVEOUT, attack/retreat → OVEROUT, harvest → REPORT3); a **vehicle** says a (host-random, so it never
    /// touches the sim RNG) REPORT3 / AFFIRM. Falls back to AFFIRM.
    private func playOrderVoice(unitSlot: Int?, kind: OrderKind?) {
        guard let slot = unitSlot else { audio.play(.acknowledge); return }
        if isFootUnit(slot) {
            switch kind {
                case .move:    audio.play(.moveOut)
                case .attack, .retreat: audio.play(.overOut)
                case .harvest: audio.play(.report3)
                case nil:      audio.play(.acknowledge)
            }
        } else {
            audio.play(Bool.random() ? .report3 : .acknowledge)
        }
    }

    private func isFootUnit(_ slot: Int) -> Bool {
        guard let state = simulation?.state, slot < state.units.count,
              let ut = UnitType(rawValue: Int(state.units[slot].o.type)) else { return false }
        return UnitInfo[ut].movementType == .foot
    }

    // MARK: - Per-frame loop (driven by the scene)

    /// Apply queued commands, advance the sim `ticks` ticks, and refresh the derived info; returns the
    /// latest frame. `ticks == 0` (slow-speed throttling between steps) re-publishes the current frame
    /// without advancing, so the camera / selection / minimap keep tracking smoothly.
    func advance(ticks: Int) -> FrameInfo? {
        guard var sim = simulation else { return nil }
        guard ticks > 0 else { return lastFrame }
        if let unitScript {
            let commands = controller.drainCommands() + drainPending()
            if !commands.isEmpty {
                let orders = UnitOrders(scriptInfo: unitScript)
                // Palace super-weapon commands need the Simulation's activation context; everything else is a
                // unit/factory order applied to the state directly.
                for c in commands where !sim.applyPalaceCommand(c) { orders.apply(c, in: &sim.state) }
            }
        }
        // Listener = the camera centre, in sub-tile world units (256/tile; the viewport is in 16-px tiles),
        // so combat/explosion sounds attenuate by distance.
        audio.setListener(x: Int(viewport.centerX * 16), y: Int(viewport.centerY * 16))
        for _ in 0 ..< ticks {
            sim.tick()
            // Play this tick's gameplay sounds (combat fire, explosions) — the full SoundEvent (with its
            // world position) so the sink can attenuate by distance. Unmapped voice ids are silent no-ops.
            for event in sim.state.soundEvents { audio.play(event) }
            // Global UI feedback the sim raised this tick (`Sound_Output_Feedback`): un-attenuated spoken
            // announcements. `48` = base-under-attack (its own voice + banner + battle music); every other
            // index (unit/structure destroyed, threat warnings, deploy, starport, bloom, missile) is a
            // `FeedbackVoice` sequence played by `playFeedback`.
            for feedback in sim.state.pendingFeedback {
                if feedback == 48 {
                    postNotice("Your base is under attack"); audio.play(.houseUnderAttack); music.enterBattle()
                } else {
                    playFeedback(feedback)
                }
            }
        }
        simulation = sim
        let frame = sim.makeFrameInfo()
        lastFrame = frame
        refreshMinimapBase(frame)   // keep the minimap terrain current (structures, walls, craters, spice)
        refreshDerived(frame)
        return frame
    }

    /// Rebuild the cached minimap terrain image when the map's tiles have changed since it was last built.
    /// The base was previously built only at scenario load, so the minimap showed the *starting* map; the
    /// terrain actually changes during play (structures bake into the ground tiles via `Structure_UpdateMap`,
    /// plus walls / craters / spice depletion). A cheap rolling hash over the tiles gates the rebuild so we
    /// don't re-extract 64×64 tiles (and allocate a `CGImage`) every tick when nothing moved.
    private func refreshMinimapBase(_ frame: FrameInfo) {
        var hash = 5381
        hash = (hash &* 33) ^ (showFog ? 1 : 0)   // toggling fog re-tints the whole base
        for t in frame.tiles {
            hash = (hash &* 33) ^ t.groundSpriteIndex
            hash = (hash &* 33) ^ t.overlaySpriteIndex
            if showFog { hash = (hash &* 33) ^ (t.isUnveiled ? 0 : 0x5A5A) }   // reveals darken/clear cells
        }
        guard hash != minimapTilesHash || minimapBase == nil else { return }
        minimapTilesHash = hash
        let source = minimapSource ?? SpriteSource.make(assets: assets)
        minimapSource = source
        minimapBase = Minimap.baseImage(frame: frame, source: source, palette: assets.palette, showFog: showFog)
    }

    private func refreshDerived(_ frame: FrameInfo) {
        updateRadar(frame)
        // Drop a dead selection, then republish only when something the panels show actually changed
        // (guarded so the per-tick refresh doesn't churn SwiftUI 60×/sec).
        if currentInfo() == nil && !controller.selection.isEmpty { controller.deselect() }
        let info = currentInfo()
        let selectionChanged = info != selection
        if selectionChanged { selection = info }
        let orderChanged = controller.pendingOrder != pendingOrder
        if orderChanged { pendingOrder = controller.pendingOrder }

        // Level outcome: latch + show the banner, and pause the game once it ends. Kept immediate (above the
        // HUD throttle) so victory/defeat never lags behind the tick that decided it.
        let end = simulation?.state.gameEndState ?? .playing
        if end != gameEnd {
            gameEnd = end
            if end != .playing {
                userPaused = true; applyPause()
                end == .won ? music.win(house: playerHouse) : music.lose(house: playerHouse)
            }
        }

        // The steady-state panel derivations are expensive (they drive SwiftUI re-layout across every tool
        // window) but only need ~10 Hz — a ticking credits/power/build readout is indistinguishable from 60
        // Hz. Throttle them, but always refresh on an interaction (selection/order change) so panels respond
        // instantly. `hudThrottle.tick()` is the left operand, so the cadence advances every frame.
        guard hudThrottle.tick() || selectionChanged || orderChanged else { return }

        // Only houses actually present on the map (≥1 unit or structure) — drop merely-activated empty houses.
        let present = housesOnMap()
        let econ = frame.houses
            .filter { (showAllEconomies || $0.id == playerHouse) && present.contains(UInt8($0.id.rawValue)) }
            .map { HouseEconomy(house: $0.id.displayName, isPlayer: $0.id == playerHouse,
                                credits: $0.credits, storage: $0.creditsStorage,
                                power: $0.powerProduction, powerUsed: $0.powerUsage) }
        if econ != economy { economy = econ }

        let credits = frame.houses.first { $0.id == playerHouse }?.credits ?? 0
        if credits != playerCredits { playerCredits = credits }
        refreshBuild()
        refreshStructureActions()
        refreshTileInfo()
        refreshHints(frame)
    }

    /// Drive the minimap radar from the player house's `radarActivated`: on a change, play the STATIC.WSA
    /// "tuning" animation (forward = coming online, backward = going dark). The announcer voice (feedback
    /// 28/29) is emitted by the sim and played by `playFeedback`; this only handles the visual transition.
    private func updateRadar(_ frame: FrameInfo) {
        let nowActive = frame.houses.first { $0.id == playerHouse }?.radarActivated ?? false
        if nowActive != radarActive {
            radarActive = nowActive
            if !radarStaticFrames.isEmpty {
                // Dune II plays the tuning reel REVERSED coming online (`activate ? frameCount - frame`) and
                // FORWARD going dark (`House_UpdateRadarState`, house.c): ON ⇒ last frame down to 0;
                // OFF ⇒ 0 up to the last.
                radarStaticForward = !nowActive
                radarStaticFrameIndex = nowActive ? radarStaticFrames.count - 1 : 0
                radarStaticTick = 0
            }
        }
        // Advance the tuning animation one WSA frame every couple of render frames (~Dune II's cadence).
        guard let idx = radarStaticFrameIndex else { return }
        radarStaticTick += 1
        if radarStaticTick >= 2 {
            radarStaticTick = 0
            let next = radarStaticForward ? idx + 1 : idx - 1
            radarStaticFrameIndex = (0 ..< radarStaticFrames.count).contains(next) ? next : nil
        }
    }

    /// Toggle the pause (the toolbar button + spacebar).
    /// The player's manual pause toggle (space bar).
    public func togglePause() { userPaused.toggle(); applyPause() }
    /// Freeze the game while a transient UI surface is open (a save/load dialog, the options or mentat popover).
    /// Balanced with `endUIPause`; nestable. The game resumes to the player's own pause once all close.
    public func beginUIPause() { uiPauseCount += 1; applyPause() }
    public func endUIPause() { if uiPauseCount > 0 { uiPauseCount -= 1 }; applyPause() }

    /// Player hints (`GUI_DisplayHint` family): a transient banner on construction-complete, low power, or
    /// out of funds. All derived from the player's economy + factory state each frame — no new sim events.
    private func refreshHints(_ frame: FrameInfo) {
        if noticeFrames > 0 { noticeFrames -= 1; if noticeFrames == 0 { notice = nil } }
        guard let sim = simulation else { return }
        let state = sim.state
        let ph = UInt8(playerHouse.rawValue)

        // Low power — production < usage (House_CalculatePowerAndCredit's low-power state). Edge-triggered.
        if let p = frame.houses.first(where: { $0.id == playerHouse }) {
            let low = p.powerUsage > p.powerProduction
            if low && !wasLowPower { postNotice("Low power — build a windtrap") }
            wasLowPower = low
        }

        // Construction complete — a player factory's product just became ready (edge-triggered per factory).
        var nowReady: Set<Int> = []
        for i in state.structures.indices where state.structures[i].o.flags.contains(.used) {
            let s = state.structures[i]
            guard s.o.houseID == ph, let type = StructureType(rawValue: Int(s.o.type)),
                  StructureInfo[type].o.flags.contains(.factory) else { continue }
            if let bs = sim.buildState(structureSlot: i), bs.isReady {
                nowReady.insert(i)
                if !readyFactories.contains(i) { postNotice("\(bs.displayName) ready"); audio.play(.houseConstruct) }
            }
        }
        readyFactories = nowReady
    }

    /// Show a transient hint banner for ~3 seconds (≈180 frames at 60 fps).
    private func postNotice(_ message: String) {
        if notice != message { notice = message }
        noticeFrames = 180
    }

    /// Flash an "insufficient funds" hint (a refused build/order). Called by the build/order paths.
    func noticeInsufficientFunds() { postNotice("Insufficient funds") }

    /// The set of house ids with at least one used unit or structure — i.e. actually on the map (vs a house
    /// merely activated for the economy via `[HOUSES]`, which the Economy panel should not list).
    private func housesOnMap() -> Set<UInt8> {
        guard let state = simulation?.state else { return [] }
        var present = Set<UInt8>()
        for u in state.units where u.o.flags.contains(.used) { present.insert(u.o.houseID) }
        for s in state.structures where s.o.flags.contains(.used) { present.insert(s.o.houseID) }
        return present
    }

    /// Recompute the selected player structure's repair/upgrade availability + (for a starport) its CHOAM
    /// stock. Published only on change.
    private func refreshStructureActions() {
        guard let slot = selectedStructureSlot, let sim = simulation,
              let type = StructureType(rawValue: Int(sim.state.structures[slot].o.type)) else {
            if structureActions != nil { structureActions = nil }
            if isStarportSelected { isStarportSelected = false }
            if !starportStock.isEmpty { starportStock = [] }
            if !starportCart.isEmpty { starportCart = [:] }
            if starportDelivery != nil { starportDelivery = nil }
            if superWeapon != nil { superWeapon = nil }
            if missileTargeting != nil { missileTargeting = nil }   // selection gone ⇒ abandon a pending target-select
            return
        }
        let s = sim.state.structures[slot]

        // A selected player palace: surface its house super-weapon + readiness (countdown at 0 = ready).
        if type == .palace, let house = HouseID(rawValue: Int(s.o.houseID)),
           let weapon = SuperWeaponState.Weapon(rawValue: Int(HouseInfo[house].specialWeapon)) {
            let sw = SuperWeaponState(slot: slot, weapon: weapon, ready: s.countDown == 0)
            if sw != superWeapon { superWeapon = sw }
        } else if superWeapon != nil { superWeapon = nil }
        let actions = StructureActions(
            slot: slot,
            canRepair: s.o.hitpoints < StructureInfo[type].o.hitpoints,
            // Upgrading is only offered at **full health** — mirrors OpenDUNE's factory-window gate
            // `Structure_IsUpgradable(s) && si->o.hitpoints == s->o.hitpoints` (`structure.c:1466`). A damaged
            // building must be repaired to full first. (The core `structureSetUpgradingState` itself doesn't
            // re-check HP — the requirement lives in the GUI that surfaces the option.)
            canUpgrade: s.upgradeTimeLeft != 0 && !s.o.flags.contains(.upgrading)
                && s.o.hitpoints == StructureInfo[type].o.hitpoints,
            isRepairing: s.o.flags.contains(.repairing),
            isUpgrading: s.o.flags.contains(.upgrading))
        if actions != structureActions { structureActions = actions }

        if isStarportSelected != (type == .starport) { isStarportSelected = type == .starport }
        var stock: [StarportItem] = []
        if type == .starport {
            // Roll fresh CHOAM prices once per starport selection (drawing the sim LCG, as opening the window
            // does in the original); re-use them on the per-tick refreshes so the list doesn't re-roll/flicker.
            // A different starport selected ⇒ a fresh window: re-roll and drop any half-built order.
            if pricedStarport != slot {
                pricedStarport = slot
                starportPriceByType = [:]
                starportCart = [:]
                for t in sim.state.starportAvailable.indices where sim.state.starportAvailable[t] > 0 {
                    guard let ut = UnitType(rawValue: t) else { continue }
                    let base = UInt16(clamping: Int(UnitInfo[ut].o.buildCredits))
                    starportPriceByType[t] = simulation?.state.starportPrice(buildCredits: base) ?? base
                }
            }
            // Every type the starport ever stocked: `> 0` = in stock (orderable), `-1` = sold out (shown,
            // greyed). `0` = never offered here (hidden), as in OpenDUNE (`g_starportAvailable` semantics).
            for t in sim.state.starportAvailable.indices where sim.state.starportAvailable[t] != 0 {
                guard let ut = UnitType(rawValue: t) else { continue }
                let price = starportPriceByType[t] ?? UInt16(clamping: Int(UnitInfo[ut].o.buildCredits))
                stock.append(StarportItem(objectType: UInt16(t), displayName: ut.displayName,
                                          cost: Int(price), available: max(0, Int(sim.state.starportAvailable[t]))))
            }
            // Drop any cart line whose type sold out from under it (e.g. the AI bought the last one). Guarded
            // so the per-tick refresh doesn't churn observation when nothing changed.
            let pruned = starportCart.filter { key, _ in stock.contains { $0.objectType == key && !$0.soldOut } }
            if pruned != starportCart { starportCart = pruned }
            // The player house's frigate-delivery countdown (a pending order ⇒ `starportLinkedID != 0xFFFF`).
            let ph = Int(playerHouse.rawValue)
            if ph < sim.state.houses.count, sim.state.houses[ph].starportLinkedID != 0xFFFF {
                let total = Double(HouseInfo[playerHouse].starportDeliveryTime)
                let left = Double(sim.state.houses[ph].starportTimeLeft)
                let f = total > 0 ? max(0, min(1, (total - left) / total)) : 0
                let d = StarportDelivery(fraction: f)
                if starportDelivery != d { starportDelivery = d }
            } else if starportDelivery != nil { starportDelivery = nil }
        } else {
            if pricedStarport != nil { pricedStarport = nil; starportPriceByType = [:] }
            if !starportCart.isEmpty { starportCart = [:] }
            if starportDelivery != nil { starportDelivery = nil }
        }
        if stock != starportStock { starportStock = stock }
    }

    /// The selected structure's pool slot iff it's a **player-owned** structure (any type, not just a factory).
    private var selectedStructureSlot: Int? {
        guard case let .structure(slot) = controller.selection, let state = simulation?.state,
              slot < state.structures.count, state.structures[slot].o.flags.contains(.used),
              state.structures[slot].o.houseID == UInt8(playerHouse.rawValue) else { return nil }
        return slot
    }

    /// True when a player-owned building is the current selection (so the r/u/s keys drive repair/upgrade/stop
    /// rather than unit orders).
    var isBuildingSelected: Bool { selectedStructureSlot != nil }

    /// Toggle the selected structure's self-repair.
    func repairSelected() { if let slot = selectedStructureSlot { enqueue(.repair(structure: UInt16(slot))); audio.play(.select) } }
    /// Toggle the selected structure's upgrade.
    func upgradeSelected() { if let slot = selectedStructureSlot { enqueue(.upgrade(structure: UInt16(slot))); audio.play(.select) } }
    /// The `s` key for a selected building: stop an in-progress repair or upgrade (a no-op otherwise). Sends
    /// the repair/upgrade *toggle* command only when the matching flag is set, so it can only ever stop —
    /// never start — the activity.
    func stopBuildingActivity() {
        guard let slot = selectedStructureSlot, let s = simulation?.state.structures[slot] else { return }
        var acted = false
        if s.o.flags.contains(.repairing) { enqueue(.repair(structure: UInt16(slot))); acted = true }
        if s.o.flags.contains(.upgrading) { enqueue(.upgrade(structure: UInt16(slot))); acted = true }
        if acted { audio.play(.acknowledge) }
    }
    /// Order one `objectType` from the selected starport (CHOAM buy). Immediate single order — used by the
    /// legacy inspector panel; the sidebar uses the `cart*` batch API below.
    func orderFromStarport(_ objectType: UInt16) {
        guard let slot = selectedStructureSlot else { return }
        let price = starportPriceByType[Int(objectType)] ?? 0
        guard playerCredits >= Int(price) else { noticeInsufficientFunds(); return }
        enqueue(.starportOrder(structure: UInt16(slot), objectType: objectType, price: price))
        audio.play(.select)
    }

    // MARK: Starport order cart

    /// The unit price for a starport item (the rolled CHOAM price), or its base cost if not yet rolled.
    private func starportPrice(_ objectType: UInt16) -> Int {
        Int(starportPriceByType[Int(objectType)] ?? UInt16(clamping: (UnitType(rawValue: Int(objectType)).map { Int(UnitInfo[$0].o.buildCredits) }) ?? 0))
    }
    /// Total units staged in the CHOAM cart.
    var cartUnitCount: Int { starportCart.values.reduce(0, +) }
    /// Total credits the staged cart would cost (charged on `sendStarportOrder`).
    var cartTotalCost: Int { starportCart.reduce(0) { $0 + $1.value * starportPrice($1.key) } }
    /// How many of `objectType` are staged in the cart.
    func cartCount(_ objectType: UInt16) -> Int { starportCart[objectType] ?? 0 }
    /// Whether one more of `item` can be staged: in stock (cart count below available) and the running total
    /// stays within the player's credits (the order is charged on send, as a batch).
    func canAddToCart(_ item: StarportItem) -> Bool {
        !item.soldOut && cartCount(item.objectType) < item.available
            && cartTotalCost + item.cost <= playerCredits
    }
    /// Stage one more `objectType` in the cart (no charge yet), if `canAddToCart`.
    func cartAdd(_ objectType: UInt16) {
        guard let item = starportStock.first(where: { $0.objectType == objectType }), canAddToCart(item) else {
            if (starportStock.first { $0.objectType == objectType }).map({ cartCount(objectType) >= $0.available }) == true {
                postNotice("Out of stock")
            } else { noticeInsufficientFunds() }
            return
        }
        starportCart[objectType, default: 0] += 1
        audio.play(.select)
    }
    /// Remove one staged `objectType` from the cart.
    func cartRemove(_ objectType: UInt16) {
        guard let n = starportCart[objectType], n > 0 else { return }
        if n == 1 { starportCart[objectType] = nil } else { starportCart[objectType] = n - 1 }
        audio.play(.select)
    }
    /// Discard the whole staged order without ordering (nothing was charged).
    func clearStarportCart() { if !starportCart.isEmpty { starportCart = [:]; audio.play(.select) } }
    /// Dispatch the staged cart: one `.starportOrder` per unit (the sim charges + decrements stock + arms the
    /// frigate-delivery countdown per unit, batching them into one delivery). Clears the cart.
    func sendStarportOrder() {
        guard let slot = selectedStructureSlot, cartUnitCount > 0 else { return }
        for (objectType, count) in starportCart {
            let price = UInt16(clamping: starportPrice(objectType))
            for _ in 0 ..< count {
                enqueue(.starportOrder(structure: UInt16(slot), objectType: objectType, price: price))
            }
        }
        starportCart = [:]
        audio.play(.acknowledge)
    }

    /// Fire the selected ready player palace's super-weapon. The death-hand arms a target click (resolved by
    /// `launchMissileAt`); the Fremen call / saboteur fire immediately (no target).
    func launchSuperWeapon() {
        guard let sw = superWeapon, sw.ready else { return }
        switch sw.weapon {
            case .missile: missileTargeting = sw.slot; audio.play(.select)
            case .fremen, .saboteur:
                enqueue(.activateSuperWeapon(structure: UInt16(sw.slot)))
                audio.play(.acknowledge)
        }
    }

    /// The death-hand target-select click: launch the missile at the clicked tile and leave targeting mode.
    func launchMissileAt(tileX: Int, tileY: Int) {
        guard let slot = missileTargeting else { return }
        enqueue(.launchHouseMissile(structure: UInt16(slot), tile: UInt16(tileY * 64 + tileX)))
        missileTargeting = nil
        audio.play(.acknowledge)
    }

    func cancelMissileTargeting() { missileTargeting = nil }

    /// Recompute the selected factory's buildable list + in-progress build (cheap; published only on change
    /// so the inspector doesn't churn each tick). Clears when the selection isn't a player-owned factory.
    private func refreshBuild() {
        guard let slot = selectedFactorySlot, let sim = simulation else {
            if isFactorySelected { isFactorySelected = false }
            if !buildOptions.isEmpty { buildOptions = [] }
            if buildProgress != nil { buildProgress = nil }
            if placement != nil { placement = nil }
            return
        }
        if !isFactorySelected { isFactorySelected = true }
        // Hide items the current campaign level hasn't unlocked yet (as the original does — they appear only
        // once the mission reaches their tier). Prerequisite/upgrade-locked items stay, greyed, since they're
        // reachable this mission.
        let b = sim.buildOptions(forStructure: slot).filter { !$0.isCampaignGated }
        if b != buildOptions { buildOptions = b }
        let st = sim.buildState(structureSlot: slot)
        if st != buildProgress { buildProgress = st }
    }

    /// The selected structure's pool slot, iff it's a **player-owned factory** (else `nil`).
    private var selectedFactorySlot: Int? {
        guard case let .structure(slot) = controller.selection, let state = simulation?.state,
              slot < state.structures.count, state.structures[slot].o.flags.contains(.used),
              let type = StructureType(rawValue: Int(state.structures[slot].o.type)),
              StructureInfo[type].o.flags.contains(.factory), type != .starport,   // the starport orders, not builds
              state.structures[slot].o.houseID == UInt8(playerHouse.rawValue) else { return nil }
        return slot
    }

    // MARK: - Input (forwarded from the scene's mouse handling)

    var selectionSlot: Selection { controller.selection }

    func leftClickTile(_ x: Int, _ y: Int) {
        let hit = pick(x, y)
        let pending = controller.pendingOrder
        let wasArmed = pending != nil && !controller.selectedUnits.isEmpty
        controller.leftClick(tileX: x, tileY: y, hit: hit)
        if wasArmed { playOrderVoice(unitSlot: controller.selectedUnits.first, kind: pending) }
        else if hit.unitSlot != nil { playSelectVoice(unitSlot: hit.unitSlot) }
        else if !hit.isEmpty { audio.play(.select) }   // a structure
        pendingOrder = controller.pendingOrder
        selection = currentInfo()
        // Clicking a bare tile (nothing selectable there, not completing an order) inspects that tile;
        // selecting a unit/structure clears the tile inspection.
        inspectedTile = (selection == nil && !wasArmed) ? (x, y) : nil
        refreshTileInfo()
    }

    /// Drag-select: select every player-owned, on-map, normal unit whose tile falls in the box `[from, to]`
    /// (a verification-client convenience; the original selects one unit at a time). Replaces the selection.
    func dragSelect(fromTileX: Int, fromTileY: Int, toTileX: Int, toTileY: Int) {
        guard let state = simulation?.state else { return }
        let minX = min(fromTileX, toTileX), maxX = max(fromTileX, toTileX)
        let minY = min(fromTileY, toTileY), maxY = max(fromTileY, toTileY)
        let ph = UInt8(playerHouse.rawValue)
        var slots: [Int] = []
        for i in state.units.indices where state.units[i].o.flags.contains(.used) {
            let u = state.units[i]
            guard u.o.houseID == ph, !u.o.flags.contains(.isNotOnMap),
                  let ut = UnitType(rawValue: Int(u.o.type)), UnitInfo[ut].flags.contains(.isNormalUnit) else { continue }
            let tx = Int(u.o.position.x) / 256, ty = Int(u.o.position.y) / 256
            if tx >= minX, tx <= maxX, ty >= minY, ty <= maxY { slots.append(i) }
        }
        // Keep only the most-numerous unit type — a mixed group (e.g. trike + harvester) can't share one
        // order, so the box selects the dominant type.
        let dominant = InputController.dominantGroup(slots, typeOf: { Int(state.units[$0].o.type) })
        controller.selectGroup(dominant)
        selection = currentInfo()
        inspectedTile = nil; refreshTileInfo()
        if !dominant.isEmpty { playSelectVoice(unitSlot: dominant.first) }
    }

    /// How many units are in the current (drag) selection — shown in the inspector header.
    var selectedUnitCount: Int { controller.selectedUnits.count }

    func rightClickTile(_ x: Int, _ y: Int) {
        let willOrder = !controller.selectedUnits.isEmpty
        let harvester = isSelectedHarvester(), enemy = isEnemy(x, y)
        controller.rightClick(tileX: x, tileY: y, enemyTarget: enemy, harvester: harvester)
        if willOrder {
            let kind: OrderKind = harvester ? .harvest : (enemy ? .attack : .move)
            playOrderVoice(unitSlot: controller.selectedUnits.first, kind: kind)
        }
        pendingOrder = controller.pendingOrder
    }

    /// True only when a **single** harvester is selected — its right-click default action is Harvest (move to
    /// the tile and harvest/seek spice). A multi-unit group gets a plain move/attack instead.
    private func isSelectedHarvester() -> Bool {
        guard controller.selectedUnits.count == 1, let state = simulation?.state else { return false }
        let slot = controller.selectedUnits[0]
        guard slot < state.units.count else { return false }
        return state.units[slot].o.type == UInt8(UnitType.harvester.rawValue)
    }

    // Inspector actions.
    func arm(_ kind: OrderKind) { controller.beginOrder(kind); audio.play(.select); pendingOrder = controller.pendingOrder }
    func stopSelected() { controller.stopSelected(); audio.play(.acknowledge) }

    /// Issue a `PanelAction` (inspector button or keyboard shortcut). A targeted action (Attack/Move/Harvest)
    /// arms a click; an immediate action (Guard/Retreat/Return/Deploy/Destruct/…) is applied to **every**
    /// selected unit straight away as `Command.setAction`.
    func issue(_ action: PanelAction) {
        if action.targeted, let kind = action.type.orderKind {
            arm(kind)
        } else if !controller.selectedUnits.isEmpty {
            for slot in controller.selectedUnits { enqueue(.setAction(unit: UInt16(slot), action: UInt8(action.type.rawValue))) }
            audio.play(.acknowledge)
        }
    }

    /// Issue an action by `ActionType` (the keyboard shortcuts) — only if it's one of the selected unit's
    /// player actions (`actionsPlayer`), so e.g. `a`=Attack is ignored for a harvester, `r`=Return for a tank.
    /// Targeted actions (`selectionType == .target`: Attack/Move/Harvest) arm a click; the rest apply at once.
    func issueAction(_ type: ActionType) {
        guard let slot = controller.selectedUnits.first, let state = simulation?.state, slot < state.units.count,
              let ut = UnitType(rawValue: Int(state.units[slot].o.type)),
              UnitInfo[ut].o.actionsPlayer.contains(type) else { return }
        issue(PanelAction(type: type, targeted: ActionInfo[type].selectionType == .target))
    }
    func deselect() { controller.deselect(); selection = nil; pendingOrder = nil; inspectedTile = nil; tileInfo = nil }

    /// Derive the inspected bare tile's parameters from the live map (nil unless a tile is being inspected and
    /// nothing is selected). Republished only on change so the per-tick refresh doesn't churn SwiftUI.
    private func refreshTileInfo() {
        guard selection == nil, let (x, y) = inspectedTile, let sim = simulation else {
            if tileInfo != nil { tileInfo = nil }
            return
        }
        let packed = UInt16(y * 64 + x)
        let tile = sim.state.map[Int(packed)]
        let land = DefaultMapPrimitives().landscapeType(tile, tileIDs: sim.state.tileIDs)
        // The tile's house only means something on owned terrain (concrete / wall / a stamped structure).
        let owned = land == .concreteSlab || land == .wall || land == .structure || land == .destroyedWall
        let info = TileInfo(
            tileX: x, tileY: y, packed: Int(packed), landscape: land.displayName,
            groundTileID: Int(tile.groundTileID), overlayTileID: Int(tile.overlayTileID),
            isSpice: land == .spice || land == .thickSpice,
            owner: owned ? HouseID(rawValue: Int(tile.houseID))?.displayName : nil,
            isUnveiled: tile.isUnveiled, isBuildable: LandscapeInfo[land].isValidForStructure)
        if info != tileInfo { tileInfo = info }
    }

    // MARK: - Building

    private func enqueue(_ command: Command) { pendingCommands.append(command) }
    private func drainPending() -> [Command] { defer { pendingCommands.removeAll() }; return pendingCommands }

    /// Start the selected factory building `objectType` (a `Buildable.objectType`).
    func startBuild(_ objectType: UInt16) {
        guard let slot = selectedFactorySlot else { return }
        // A locked item (missing prerequisites / campaign / upgrade) can't be started — the panel greys it,
        // but guard here too so a stale tap is a no-op.
        guard let option = buildOptions.first(where: { $0.item.objectType == objectType }), option.isAvailable else { return }
        // No credit gate: construction may be *started* underfunded — like the original, the cost is billed
        // incrementally and the build auto-pauses (`.onHold`) when the house runs out of money mid-build
        // (`structureTickStructure`, `structure.c:266`). (Starport CHOAM orders, by contrast, are paid upfront
        // and keep their affordability check in `starportOrder`.)
        enqueue(.build(structure: UInt16(slot), objectType: objectType))
        audio.play(.select)
    }

    /// Cancel the selected factory's in-progress build (refunds the remainder).
    func cancelBuild() {
        guard let slot = selectedFactorySlot else { return }
        enqueue(.cancelBuild(structure: UInt16(slot)))
        placement = nil
        audio.play(.acknowledge)
    }

    /// Pause the selected factory's in-progress build (`widget_click.c:124`, `STR_D_DONE`).
    func pauseBuild() {
        guard let slot = selectedFactorySlot else { return }
        enqueue(.pauseBuild(structure: UInt16(slot)))
        audio.play(.select)
    }

    /// Resume the selected factory's held ("on hold") build — clears the hold so it continues once the house
    /// has credits again (the faithful click-to-resume; `widget_click.c:107`, `STR_ON_HOLD`).
    func resumeBuild() {
        guard let slot = selectedFactorySlot else { return }
        enqueue(.resumeBuild(structure: UInt16(slot)))
        audio.play(.select)
    }

    /// Enter placement mode for the selected construction yard's finished structure.
    func beginPlacement() {
        guard let slot = selectedFactorySlot, let sim = simulation,
              let bs = sim.buildState(structureSlot: slot), bs.isReady, bs.isStructure,
              let type = StructureType(rawValue: Int(bs.objectType)) else { return }
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        // Seed the hover tile to the viewport centre so the footprint projection shows immediately on the
        // button click (before the mouse moves over the map), then follows the cursor.
        let cx = max(0, min(63, Int(viewport.centerX / Viewport.tilePx)))
        let cy = max(0, min(63, Int(viewport.centerY / Viewport.tilePx)))
        placement = PlacementState(factorySlot: slot, type: type,
                                   width: Int(layout.size.width), height: Int(layout.size.height),
                                   hoverTileX: cx, hoverTileY: cy)
        audio.play(.select)
    }

    func cancelPlacement() { placement = nil }

    /// Update the placement preview's hovered tile (from the map's mouse-move).
    func placementHover(tileX: Int, tileY: Int) {
        guard var p = placement, p.hoverTileX != tileX || p.hoverTileY != tileY else { return }
        p.hoverTileX = tileX; p.hoverTileY = tileY
        placement = p
    }

    /// `Structure_IsValidBuildLocation` at a tile for the current placement (≥1 ok, 0 blocked, <0 ok-with-penalty).
    func placementValidity(tileX: Int, tileY: Int) -> Int16 {
        guard let p = placement, let sim = simulation else { return 0 }
        return sim.placementValidity(type: p.type, tile: UInt16(tileY * 64 + tileX)) ?? 0
    }

    /// Commit the placement at the clicked tile (no-op on a blocked spot, so the player can click again).
    func placeAt(tileX: Int, tileY: Int) {
        guard let p = placement, placementValidity(tileX: tileX, tileY: tileY) != 0 else { return }
        enqueue(.placeStructure(structure: UInt16(p.factorySlot), tile: UInt16(tileY * 64 + tileX)))
        placement = nil
        audio.play(.acknowledge)
    }

    private func pick(_ x: Int, _ y: Int) -> Selection {
        guard let state = simulation?.state else { return .none }
        let packed = UInt16(y * 64 + x)
        if let u = state.unitGetByPackedTile(packed) { return .unit(slot: u) }
        if let s = state.structureGetByPackedTile(packed) { return .structure(slot: s) }
        return .none
    }

    private func isEnemy(_ x: Int, _ y: Int) -> Bool {
        guard let state = simulation?.state, let slot = controller.selection.unitSlot, slot < state.units.count else { return false }
        let mine = state.unitHouseID(state.units[slot])
        let packed = UInt16(y * 64 + x)
        if let u = state.unitGetByPackedTile(packed) { return state.unitHouseID(state.units[u]) != mine }
        if let s = state.structureGetByPackedTile(packed) { return state.structures[s].o.houseID != mine }
        return false
    }

    // MARK: - Viewport (scroll/zoom + minimap)

    func zoomIn() { viewport.zoomIn() }
    func zoomOut() { viewport.zoomOut() }
    func scroll(dx: Double, dy: Double) { viewport.scroll(dx: dx, dy: dy, viewSize: viewSize) }
    /// Centre the map on a world point (a minimap click), in world points.
    func centerOn(worldX: Double, worldY: Double) { viewport.center(onWorldX: worldX, worldY: worldY, viewSize: viewSize) }

    // MARK: - Selection info derivation

    func selectionFootprint() -> (Int, Int) {
        guard case let .structure(slot) = controller.selection, let state = simulation?.state,
              slot < state.structures.count,
              let type = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return (1, 1) }
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        return (Int(layout.size.width), Int(layout.size.height))
    }

    /// The selection outline boxes, in **world pixels** (16 px/tile). A **structure** selection ⇒ one
    /// footprint box; a **unit (drag) group** ⇒ one tile-size box per live selected unit (each follows its
    /// sub-tile `position` smoothly). Empty when nothing live is selected.
    func selectionBoxes() -> [(centerX: Double, centerY: Double, width: Double, height: Double, isStructure: Bool)] {
        guard let state = simulation?.state else { return [] }
        let tile = 16.0
        if case let .structure(slot) = controller.selection,
           slot < state.structures.count, state.structures[slot].o.flags.contains(.used) {
            let (w, h) = selectionFootprint()
            let cornerX = Double(state.structures[slot].o.position.x) * tile / 256
            let cornerY = Double(state.structures[slot].o.position.y) * tile / 256
            return [(cornerX + Double(w) * tile / 2, cornerY + Double(h) * tile / 2, Double(w) * tile, Double(h) * tile, true)]
        }
        var boxes: [(centerX: Double, centerY: Double, width: Double, height: Double, isStructure: Bool)] = []
        for slot in controller.selectedUnits where slot < state.units.count && state.units[slot].o.flags.contains(.used) {
            let p = state.units[slot].o.position
            boxes.append((Double(p.x) * tile / 256, Double(p.y) * tile / 256, tile, tile, false))
        }
        return boxes
    }

    /// A readable "what it's doing" label for a structure: its build activity if it's producing/upgrading,
    /// otherwise its runtime `StructureState`.
    private static func structureState(_ s: Structure) -> String {
        if s.upgradeTimeLeft != 0 && s.upgradeLevel != 0 { return "Upgrading" }
        if s.objectType != 0 && s.countDown != 0 { return "Building" }
        switch s.state {
            case .justBuilt: return "Constructing"
            case .busy:      return "Working"
            case .ready:     return "Ready"
            case .idle:      return "Idle"
            case .detect:    return "—"
        }
    }

    private func currentInfo() -> SelectionInfo? {
        guard let state = simulation?.state else { return nil }
        switch controller.selection {
            case .none: return nil
            case let .unit(slot):
                guard slot < state.units.count, state.units[slot].o.flags.contains(.used),
                      let type = UnitType(rawValue: Int(state.units[slot].o.type)) else { return nil }
                let u = state.units[slot]
                let house = HouseID(rawValue: Int(state.unitHouseID(u))) ?? .harkonnen
                let p = Int(u.o.position.packed)
                let stateText = ActionType(rawValue: Int(u.actionID)).map { ActionInfo[$0].name } ?? "—"
                // The original's per-unit player action menu (`actionsPlayer`), deduped + in order, for a
                // player unit: Attack/Move/Harvest/Return/Deploy/Guard/… A `.target` action arms a click; a
                // `.unit` action applies immediately.
                var actions: [PanelAction] = []
                if house == playerHouse {
                    var seen = Set<ActionType>()
                    for a in UnitInfo[type].o.actionsPlayer.all where seen.insert(a).inserted {
                        actions.append(PanelAction(type: a, targeted: ActionInfo[a].selectionType == .target))
                    }
                }
                return SelectionInfo(kind: .unit, name: type.displayName, house: house.displayName,
                                     typeRaw: UInt16(type.rawValue), houseID: house,
                                     isPlayer: house == playerHouse, state: stateText, hitpoints: Int(u.o.hitpoints),
                                     hitpointsMax: Int(UnitInfo[type].o.hitpoints), tileX: p % 64, tileY: p / 64,
                                     unitActions: actions)
            case let .structure(slot):
                guard slot < state.structures.count, state.structures[slot].o.flags.contains(.used),
                      let type = StructureType(rawValue: Int(state.structures[slot].o.type)) else { return nil }
                let s = state.structures[slot]
                let house = HouseID(rawValue: Int(s.o.houseID)) ?? .harkonnen
                let p = Int(s.o.position.packed)
                return SelectionInfo(kind: .structure, name: type.displayName, house: house.displayName,
                                     typeRaw: UInt16(type.rawValue), houseID: house,
                                     isPlayer: house == playerHouse, state: Self.structureState(s),
                                     hitpoints: Int(s.o.hitpoints),
                                     // Base HP as the max (matching OpenDUNE's health bar), not the
                                     // power-degraded `s.hitpointsMax` (which can read below current HP).
                                     hitpointsMax: Int(StructureInfo[type].o.hitpoints), tileX: p % 64, tileY: p / 64)
        }
    }
}

/// One entry of a unit's player action menu: an `ActionType` plus whether it needs a target click
/// (`selectionType == .target`, e.g. Attack/Move/Harvest) or applies immediately (Guard/Return/Deploy/…).
struct PanelAction: Equatable, Hashable {
    var type: ActionType
    var targeted: Bool
}

/// A bare map tile's inspected parameters (the inspector shows these when no unit/structure is selected).
struct TileInfo: Equatable {
    var tileX: Int
    var tileY: Int
    var packed: Int
    var landscape: String
    var groundTileID: Int
    var overlayTileID: Int
    var isSpice: Bool
    var owner: String?
    var isUnveiled: Bool
    var isBuildable: Bool
}

extension LandscapeType {
    /// A short human label for the tile inspector.
    var displayName: String {
        switch self {
            case .normalSand:       "Sand"
            case .partialRock:      "Rock (partial)"
            case .entirelyDune, .partialDune: "Dune"
            case .entirelyRock, .mostlyRock:  "Rock"
            case .entirelyMountain, .partialMountain: "Mountain"
            case .spice:            "Spice"
            case .thickSpice:       "Thick spice"
            case .concreteSlab:     "Concrete"
            case .wall:             "Wall"
            case .structure:        "Structure"
            case .destroyedWall:    "Rubble"
            case .bloomField:       "Spice bloom"
        }
    }
}

/// One orderable line in a selected starport's CHOAM list: the unit, its rolled CHOAM price, and the current
/// stock (`available`; 0 = sold out). The per-order "cart" count is held separately in `GameModel.starportCart`
/// so the list can refresh each tick without losing the staged order.
struct StarportItem: Equatable {
    var objectType: UInt16
    var displayName: String
    var cost: Int
    var available: Int          // current stock (`g_starportAvailable`); 0 here = sold out (−1 in the sim)
    var soldOut: Bool { available <= 0 }
}

/// A pending starport delivery for the player house: how far the frigate-arrival countdown
/// (`House.starportTimeLeft` → `starportDeliveryTime`) has progressed. `fraction` 0 = just ordered, 1 = due.
struct StarportDelivery: Equatable {
    var fraction: Double
}

/// Repair/upgrade availability for the selected player structure (the inspector's structure-command buttons).
struct StructureActions: Equatable {
    var slot: Int
    var canRepair: Bool
    /// True only when a further upgrade exists *and* the building is at full health (the original only offers
    /// the upgrade option to a fully-repaired structure — see `refreshStructureActions`).
    var canUpgrade: Bool
    var isRepairing: Bool
    var isUpgrading: Bool
}

/// The selected player palace's super-weapon (which weapon + whether the countdown has recharged).
struct SuperWeaponState: Equatable {
    /// `HouseInfo.specialWeapon`: 1 = Harkonnen/Sardaukar death-hand missile, 2 = Atreides/Fremen call,
    /// 3 = Ordos/Mercenary saboteur.
    enum Weapon: Int { case missile = 1, fremen = 2, saboteur = 3 }
    var slot: Int
    var weapon: Weapon
    var ready: Bool

    /// The launch button's title.
    var title: String {
        switch weapon {
            case .missile:  "Launch Death Hand"
            case .fremen:   "Call Fremen"
            case .saboteur: "Deploy Saboteur"
        }
    }
    var systemImage: String {
        switch weapon {
            case .missile:  "flame"
            case .fremen:   "person.3"
            case .saboteur: "bolt.trianglebadge.exclamationmark"
        }
    }
    /// The death-hand needs a target click; the other two fire in place.
    var needsTarget: Bool { weapon == .missile }
}

/// Active structure-placement mode: a finished construction-yard product awaiting a valid map click.
struct PlacementState: Equatable {
    var factorySlot: Int
    var type: StructureType
    var width: Int
    var height: Int
    var hoverTileX: Int?
    var hoverTileY: Int?
}

/// A house's economy for the Economy window.
struct HouseEconomy: Equatable, Identifiable {
    var house: String
    var isPlayer: Bool
    var credits: Int, storage: Int, power: Int, powerUsed: Int
    var id: String { house }
}

/// The selected entity's properties for the Inspector window.
struct SelectionInfo: Equatable {
    enum Kind: Equatable { case unit, structure }
    var kind: Kind
    var name: String, house: String
    /// The selected entity's `UnitType.rawValue` / `StructureType.rawValue` (per `kind`) and owning house —
    /// so the sidebar can render its sprite (house-recoloured). `name` is the display string for that type.
    var typeRaw: UInt16 = 0
    var houseID: HouseID = .harkonnen
    var isPlayer: Bool
    /// What the entity is currently doing — a unit's action ("Move", "Attack", "Guard", "Harvest", …) or a
    /// structure's activity ("Building", "Working", "Idle", …).
    var state: String
    var hitpoints: Int, hitpointsMax: Int
    var tileX: Int, tileY: Int
    /// The player order buttons for this entity — the original's per-unit `actionsPlayer` menu (Attack/Move/
    /// Harvest/Return/Deploy/Guard/…), deduped and in order. Empty for structures and non-player units.
    var unitActions: [PanelAction] = []
}
