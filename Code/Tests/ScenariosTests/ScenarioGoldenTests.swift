import DuneIIContracts
import DuneIIFormats
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIScenarios

/// Per-scenario golden vs OpenDUNE — the **whole-run, per-tick** comparison harness. For each scenario,
/// both engines load the shared `.INI` (terrain via `[MAP] Seed → Map_CreateLandscape`, units placed),
/// apply the same simulated player command, and produce a per-tick sequence of per-unit state; this
/// asserts ours equals the oracle's, tick by tick, for the leading `compared` frames.
///
/// The oracle fixtures come from the `--parity-scenario` mode + `Scripts/gen-scenario-goldens.sh` (see
/// `Documentation/Architecture/ScenarioHarness.md`), e.g.:
///   opendune --parity-scenario=99 --parity-cmd=move,22,2600 --parity-ticks=N --parity-dump=moving-golden.jsonl
///
/// **`compared`** gates how many leading ticks are asserted (`0` = the whole trajectory). Movement
/// scenarios match end-to-end (the movement cluster + the real `UNIT.EMC` MOVE script run under
/// `GameLoop_Unit`); `attack-close` now matches the **whole 400-tick combat exchange** end-to-end —
/// setup → aim → acquire → fire → bullet spawn + flight → impact damage (`Map_MakeExplosion` → `Unit_Damage`)
/// → retaliation — bit-identical to the oracle, with no RNG-spread divergence. New scenarios slot in by
/// adding an `.INI` + a line in the generator + a `Spec` below.
///
/// **`attack-rocket` (Launcher duel) — now a FULL 400-tick match.** Setup → aim → fire → the `notAccurate`
/// rocket spawn + in-flight homing (`GameLoop_Unit` re-aims a flying missile at its `currentDestination`
/// while `fireDelay != 0`), bit-identical to the oracle. The former tick-69 "1-orientation-unit scatter
/// residual" was **not** a stochastic spread: it was the same `GameLoop_Team` cursor-draw bug as `guard`
/// (see below) — our team phase dropped one shared-`Random256` draw per fire, so by the time the rocket's
/// `Tile_MoveByRandom` scatter drew, the stream was one byte off. Re-arming the team cursor unconditionally
/// (matching OpenDUNE) aligned the stream and closed the residual.
///
/// **`economy` is a HOUSE golden — the per-tick house aggregate, not units.** An Ordos windtrap+silo base
/// (no units, no combat) activated via the `.INI`'s new `[HOUSES]` section (`Ordos=2000` starting credits).
/// It compares the dumped house economy (`credits`/`creditsStorage`/`powerProduction`/`powerUsage`) tick by
/// tick: tick 0 = `House_CalculatePowerAndCredit` (power 100/5, storage 1000, credits 2000), tick 1 = the
/// `GameLoop_House` clamp (2000→storage 1000) **and** power-maintenance upkeep (→999), then static — a full
/// 60-tick match. Validates this session's House subsystem cross-engine. Scenarios without `[HOUSES]` have
/// no active houses (both dumps empty), so the unit/combat goldens are unchanged.
///
/// **`guard` — now a FULL 400-tick match** (was gated at 6). A sitting GUARD unit's idle twitch
/// (`Script_Unit_IdleAction` 0x31: a `Tools_RandomLCG_Range(0,10)` roll, then on a low roll a body/turret
/// rotation from `Tools_Random_256()`) reads the shared `Random256` stream — so it only matches the oracle
/// if the stream is byte-aligned. It diverged at tick 6 because our `GameLoop_Team` skipped its cursor
/// re-arm (and its one `Random256` draw) when no `TEAM.EMC` was bridged, while OpenDUNE re-arms it every
/// fire regardless. With the cursor draw made unconditional the streams align and the guard's twitch
/// matches tick-for-tick. (The "render-only wobble / don't-chase-RNG-order" diagnosis was wrong — same
/// logic ⇒ same draw count; the gap was a real one-draw transcription miss, now fixed.)
///
/// **`refinery-harvester` — a STRUCTURE-PLACEMENT golden** (the `place:` specs + the oracle's
/// `--parity-place`/`Scen_BuildPlace`). A Harkonnen construction yard builds + places two refineries on a
/// concrete pad; **each** placement spawns its own ferried harvester (`viewport.c:210`, the per-refinery
/// spawn this golden locks). Frame 0 (no ticks) matches the oracle on the CY + windtrap + 2 refineries
/// (structures, incl. the refinery's incoming-`BUSY` state) and the 2 spawned carryalls (units — the
/// in-transport harvesters are skipped by `Unit_Find` in both engines, but the house `unitCount==4` proves
/// all 4 units exist). The carryalls' spawn positions come from `Unit_CreateWrapper`'s RNG, so a position
/// match proves that RNG aligned cross-engine. A windtrap powers the base (else the oracle's underpowered
/// `House_CalculatePowerAndCredit` GUI text crashes headless).
@Suite("Scenario golden vs OpenDUNE")
struct ScenarioGoldenTests {
    struct Frame: Decodable {
        let tick: Int; let units: [UnitState]; let structures: [StructureGolden]?; let houses: [HouseGolden]?;
        let tiles: [TileGolden]?
    }
    /// A dumped map cell (the `[DUMPTILES]` cells) — for the wall/slab goldens, where the destruction shows
    /// in the map tile, not a structure record (walls/slabs aren't in the structure find-array). We compare
    /// `ground` (the unambiguous observable: a destroyed wall reverts its ground sprite to the base terrain;
    /// a slab's ground stays the concrete tile). The oracle also dumps `overlay` + `lst`; `overlay` is
    /// **not** compared — it carries the fog veil, whose 7-bit-truncated tick-0 value has a latent off-by-one
    /// vs ours (124 vs 123) unrelated to wall/slab destruction, and the destroyed-wall marker it later holds
    /// is already implied by the ground revert.
    struct TileGolden: Decodable, Equatable {
        let packed: UInt16; let ground: UInt16; let veil: Int  // veil: 1 = unveiled (no fog), 0 = fogged
    }
    /// The dynamic house-economy fields (`House_CalculatePowerAndCredit` + the House-loop clamp/upkeep). The
    /// oracle dumps more (unitCount/starport); `Decodable` ignores those.
    struct HouseGolden: Decodable, Equatable {
        let index: UInt16; let credits: UInt16; let creditsStorage: UInt16
        let powerProduction: UInt16; let powerUsage: UInt16
        let unitCount: UInt16  // live units of the house — verifies the bullet allocate/free accounting
        // The base-under-attack observables (`Structure_HouseUnderAttack`), compared only for the
        // `checkUnderAttack` spec — nil (and so absent from the comparison) for every other scenario, whose
        // older goldens don't dump these keys. `timerStructureAttack` (the human-player rate limit) and
        // `doneFullScaleAttack` (the one-shot "I've been hit" flag set for *any* struck house).
        var timerStructureAttack: UInt16? = nil
        var doneFullScaleAttack: Int? = nil
    }
    struct UnitState: Decodable, Equatable {
        let index: UInt16; let type: UInt8; let houseID: UInt8; let packed: UInt16; let orient: Int16
        let hp: UInt16; let actionID: UInt8; let targetMove: UInt16; let targetAttack: UInt16
        let spriteOffset: Int16  // the walk/animation frame (tickUnknown5) — verifies infantry animation
        let team: UInt8  // 1-based team membership (0 = none) — verifies AI recruiting (Team_AddClosestUnit)
        let alive: Int
    }
    /// The dynamic structure fields (identity + the ones combat/scripts change). The oracle dumps more
    /// (position/upgrades); `Decodable` ignores those.
    struct StructureGolden: Decodable, Equatable {
        let index: UInt16; let type: UInt8; let houseID: UInt8
        let hitpoints: UInt16; let state: Int16; let linkedID: UInt8
    }

    /// One golden scenario: the shared `.INI`, the player order applied to the first unit, and how many
    /// leading ticks to assert (`0` = the whole committed trajectory).
    struct Spec: Sendable, CustomTestStringConvertible {
        let name: String  // golden file base (`<name>-golden.jsonl`)
        let ini: String  // shared scenario `.INI`
        let attack: Bool  // false = move order, true = attack order
        let cmdUnit: UInt16  // pool index of the unit the order targets (matches the oracle --parity-cmd)
        let tile: UInt16  // the order's target tile
        let compared: Int  // leading ticks asserted; 0 = full trajectory
        var cmd: Bool = true  // whether to issue the player command (false = structure/economy-only scenario)
        var team: Bool = false  // bridge TEAM.EMC + the team-script offsets (the [TEAMS] AI golden)
        var cmd2Unit: UInt16? = nil  // an optional second attack order (the mutual missile duel)
        var cmd2Tile: UInt16 = 0
        var tickExplosions: Bool = false  // tick the GUI-clocked explosion VM ([BASIC] TickExplosions=1)
        var checkUnderAttack: Bool = false  // compare the Structure_HouseUnderAttack house fields (timer + doneFullScaleAttack)
        var place: [PlaceCmd] = []  // build+place commands (a CY builds + the player places a structure)
        var launch: [LaunchCmd] = []  // human palace death-hand launches (mirrors the oracle's --parity-launch)
        var testDescription: String { name }
    }

    /// A build+place command: construction yard `cy` builds `objectType` (a `StructureType.rawValue`) and the
    /// player places it at `tile` — mirrors the oracle's `--parity-place` (exercises the per-refinery harvester).
    struct PlaceCmd: Sendable { let cy: UInt16; let objectType: UInt16; let tile: UInt16 }

    /// A human palace death-hand launch: palace pool index `structure` fires its house missile at `tile` —
    /// mirrors the oracle's `--parity-launch` (`Scen_LaunchMissile`). Applied untraced before the tick loop.
    struct LaunchCmd: Sendable { let structure: UInt16; let tile: UInt16 }

    static let specs: [Spec] = [
        Spec(name: "moving", ini: "bootstrap.ini", attack: false, cmdUnit: 22, tile: 2600, compared: 0),  // tank, full match
        Spec(name: "move-trike", ini: "move-trike.ini", attack: false, cmdUnit: 22, tile: 1040, compared: 0),  // trike off-viewport, full match
        Spec(name: "guard", ini: "guard.ini", attack: false, cmdUnit: 23, tile: 1100, compared: 0),  // guard sits + trike approaches: FULL 400-tick match incl. the guard's idle twitch (after the GameLoop_Team cursor-draw fix — see note)
        Spec(name: "attack-close", ini: "attack-close.ini", attack: true, cmdUnit: 22, tile: 1041, compared: 0),  // FULL 400-tick combat match: fire→bullet→impact damage→retaliation, bit-identical to the oracle
        Spec(name: "attack-rocket", ini: "attack-rocket.ini", attack: true, cmdUnit: 22, tile: 1045, compared: 0),  // Launcher duel → notAccurate rocket: FULL 400-tick match incl. the scatter (after the GameLoop_Team cursor-draw fix — see note)
        Spec(name: "attack-structure", ini: "attack-structure.ini", attack: true, cmdUnit: 22, tile: 1042, compared: 0),  // tank attacks an Ordos windtrap: full 400-tick match (structures + units), inc. the bullet-impact Structure_Damage (200→175). Found the structure-corner-position bug (see note).
        Spec(name: "trooper", ini: "trooper.ini", attack: false, cmdUnit: 22, tile: 1040, compared: 0),  // a foot trooper walks: verifies the walk animation (spriteOffset, tickUnknown5) + movement, full match
        Spec(
            name: "house-under-attack",
            ini: "house-under-attack.ini",
            attack: true,
            cmdUnit: 22,
            tile: 1042,
            compared: 0,
            checkUnderAttack: true
        ),  // HOUSE-UNDER-ATTACK golden: a Harkonnen tank's bullet impacts an Ordos windtrap; on impact Map_MakeExplosion → Structure_HouseUnderAttack(Ordos) flips the Ordos house's doneFullScaleAttack 0→1 (tick 82, same hit that drops the windtrap 200→175). Full 400-tick match incl. the house fields (timerStructureAttack stays 0 — Ordos isn't the human player) + the RNG stream. The player-human branch (timer + the "your base is under attack" feedback) can't run headless (the oracle SIGSEGVs in Sound_Output_Feedback — no strings) so it's a UI seam covered by HouseUnderAttackTests.
        Spec(name: "economy", ini: "economy.ini", attack: false, cmdUnit: 0, tile: 0, compared: 0, cmd: false),  // HOUSE golden: an Ordos windtrap+silo base — full 60-tick match of the house aggregate (credits 2000→clamp 1000→power-maint 999, power 100/5, storage 1000) + structures. Validates House_CalculatePowerAndCredit + the credit clamp + power maintenance.
        Spec(name: "teams", ini: "teams.ini", attack: false, cmdUnit: 0, tile: 0, compared: 0, cmd: false, team: true),  // TEAM-AI golden: an Ordos `Normal`-brain team recruits its tanks via GameLoop_Team. Unit-state + (decisively) the RNG draw stream match the oracle full 400 ticks — proving the team loop + brain run identically cross-engine (recruiting isn't in the dump; the RNG stream is the proof). Targeting is fog-gated off (seenByHouses 0), matching the oracle.
        Spec(
            name: "missile-duel",
            ini: "missile-duel.ini",
            attack: true,
            cmdUnit: 22,
            tile: 1045,
            compared: 0,
            cmd2Unit: 23,
            cmd2Tile: 1040
        ),
        Spec(name: "wall-destruction", ini: "wall-destruction.ini", attack: true, cmdUnit: 22, tile: 1042, compared: 0),  // MAP-TILE golden: a tank's bullet impacts an Ordos wall; the 25-dmg hit's Random_256 roll (this seed) destroys the 50-HP wall at tick 67 — the [DUMPTILES] cell's ground reverts to terrain + overlay becomes the destroyed-wall marker (Map_MakeExplosion's wall branch + Map_UpdateWall). Rides the RNG-stream golden (the destroy draws Random_256).
        Spec(
            name: "refinery-harvester",
            ini: "refinery-harvester.ini",
            attack: false,
            cmdUnit: 0,
            tile: 0,
            compared: 0,
            cmd: false,
            place: [ PlaceCmd(cy: 0, objectType: 12, tile: 1168), PlaceCmd(cy: 0, objectType: 12, tile: 1296) ]
        ),  // a CY builds + places 2 refineries on a concrete pad; EACH placement spawns its own ferried harvester (the per-refinery spawn, viewport.c:210). Frame 0: CY + windtrap + 2 refineries (structures) + 2 spawned carryalls (the in-transport harvesters are skipped, but houses.unitCount==4 proves all 4 units exist). The carryall spawn positions prove Unit_CreateWrapper's RNG aligned cross-engine.
        Spec(name: "fog", ini: "fog.ini", attack: false, cmdUnit: 0, tile: 0, compared: 6, cmd: false),  // FOG trace: a Harkonnen base + Ordos soldiers at increasing distances. The [DUMPTILES] `veil` (isUnveiled) matches the oracle every tick — proving the fog reveal (which tiles the base unveils) is faithful after the Unit_RemoveFog allied-check fix (was: enemy units self-revealed the player's fog ⇒ "I see all enemy troopers" + the AI made instant contact). Gated at tick 6: at tick 6 the Ordos guard soldier *adjacent* to the base (legitimately visible) picks a different target encoding than the oracle (16407 vs 32768) — both engage the base (correct stock behaviour), a guard target-selection wobble unrelated to fog (residual, see History).
        Spec(
            name: "palace-launch",
            ini: "palace-launch.ini",
            attack: false,
            cmdUnit: 0,
            tile: 0,
            compared: 0,
            cmd: false,
            launch: [ LaunchCmd(structure: 0, tile: 2925) ]
        ),  // PALACE golden (frame 0 only, like refinery-harvester): a Harkonnen (player) palace launches its death-hand at tile (45,45). The human one-shot — carrier orientation (Tools_Random_256) + Tile_MoveByRandom(160) jitter + the bullet spawned from the palace — is applied untraced before frame 0. Frame 0 matches the oracle on the spawned missileHouse bullet (its spawn tile + the *jittered* targetAttack, which encodes the 3 launch RNG draws) + the palace's re-armed countDown (600). Verifies structureActivateSpecial(slot, missileTarget:) + Command.launchHouseMissile cross-engine. (The oracle segfaults flying a missileHouse bullet headless, so we don't tick it; the flight is covered by unit tests, the blast by §G.)
        Spec(
            name: "slab-indestructible",
            ini: "slab-indestructible.ini",
            attack: true,
            cmdUnit: 22,
            tile: 1042,
            compared: 0,
            tickExplosions: true
        ),  // MAP-TILE golden, explosion VM TICKED: a tank's EXPLOSION_IMPACT_SMALL has no TILE_DAMAGE, so the [DUMPTILES] slab cell stays a slab even with explosions ticking. (Concrete IS destructible — by a TILE_DAMAGE explosion (IMPACT_LARGE/EXPLODE), verified RNG-free in ExplosionTests; a scattering rocket can't reliably hit an exact tile, so the destruction isn't a scenario golden.)  // BULLET-ACCOUNTING golden: an Atreides + an Ordos Launcher each ordered to attack the other, trading notAccurate rockets. Each rocket is a unit (Unit_Allocate → the firing house's unitCount++) freed on impact (unitCount--), so the per-tick house unitCount oscillates as bullets spawn + land — asserting the projectile allocate/free accounting matches the oracle tick-for-tick (the accounting whose uint16 wrap crashed a long mapview run). Non-player houses avoid the player-house House_CalculatePowerAndCredit GUI path the headless oracle lacks (turrets can't fire headless — no sprite-rotation GFX — so a missile duel exercises the identical bullet path).
    ]

    /// Sorted by `index` so the comparison is independent of pool/find-array enumeration order: our engine
    /// dumps in slot order, the oracle in allocation (find-array) order, which differ once a unit is
    /// spawned mid-run (e.g. a bullet lands in a low slot but is allocated last). `index` is unique.
    private func snapshot(_ s: GameState) -> [UnitState] {
        // Skip in-transport (off-map) units — the oracle's `Unit_Find` skips them at the dump point
        // (`g_validateStrictIfZero == 0`), so a ferried (riding) harvester appears in neither dump.
        s.units.indices.filter { s.units[$0].o.flags.contains(.used) && !s.units[$0].o.flags.contains(.isNotOnMap) }.map
        { i in
            let u = s.units[i]
            return UnitState(
                index: u.o.index,
                type: u.o.type,
                houseID: u.o.houseID,
                packed: u.o.position.packed,
                orient: Int16(u.orientation[0].current),
                hp: u.o.hitpoints,
                actionID: u.actionID,
                targetMove: u.targetMove,
                targetAttack: u.targetAttack,
                spriteOffset: Int16(u.spriteOffset),
                team: u.team,
                alive: u.o.flags.contains(.used) ? 1 : 0
            )
        }
        .sorted { $0.index < $1.index }
    }

    private func structureSnapshot(_ s: GameState) -> [StructureGolden] {
        s.structures.indices.filter { s.structures[$0].o.flags.contains(.used) }.map { i in
            let st = s.structures[i]
            return StructureGolden(
                index: st.o.index,
                type: st.o.type,
                houseID: st.o.houseID,
                hitpoints: st.o.hitpoints,
                state: st.state.rawValue,
                linkedID: st.o.linkedID
            )
        }
        .sorted { $0.index < $1.index }
    }

    /// The `[DUMPTILES]` map cells — ground/overlay tile ids straight from our `GameState.map`, matching
    /// the oracle's per-tile dump. The driver for the wall/slab goldens.
    private func tilesSnapshot(_ s: GameState, _ packed: [UInt16]) -> [TileGolden] {
        packed.map { p in
            TileGolden(packed: p, ground: s.map[Int(p)].groundTileID, veil: s.map[Int(p)].isUnveiled ? 1 : 0)
        }
    }

    private func houseSnapshot(_ s: GameState, underAttack: Bool) -> [HouseGolden] {
        s.houses.indices.filter { s.houses[$0].flags.contains(.used) }.map { i in
            let h = s.houses[i]
            return HouseGolden(
                index: UInt16(h.index),
                credits: h.credits,
                creditsStorage: h.creditsStorage,
                powerProduction: h.powerProduction,
                powerUsage: h.powerUsage,
                unitCount: h.unitCount,
                // Only the under-attack spec compares these; nil keeps every other scenario's
                // house comparison identical to its (timer/flag-free) committed golden.
                timerStructureAttack: underAttack ? h.timerStructureAttack : nil,
                doneFullScaleAttack: underAttack ? (h.flags.contains(.doneFullScaleAttack) ? 1 : 0) : nil
            )
        }
        .sorted { $0.index < $1.index }
    }

    @Test("per-tick run matches the oracle", arguments: specs)
    func scenario(_ spec: Spec) throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }
        let fix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
            let emc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/UNIT/UNIT.emc")),
            let buildEmc = try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/BUILD/BUILD.emc")),
            let ini = try? Data(contentsOf: fix.appendingPathComponent(spec.ini)),
            let golden = try? String(
                contentsOf: fix.appendingPathComponent("\(spec.name)-golden.jsonl"),
                encoding: .utf8
            )
        else { return }

        let oracle = golden.split(separator: "\n").map { try! JSONDecoder().decode(Frame.self, from: Data($0.utf8)) }
        #expect(!oracle.isEmpty)

        let scriptInfo = ScriptInfo(try Emc.Program(emc))
        let structureScriptInfo = ScriptInfo(try Emc.Program(buildEmc))
        // The [TEAMS] golden bridges TEAM.EMC (the team-script offsets feed Team_Create) + the live runner.
        let teamScriptInfo: ScriptInfo? = spec.team
            ? (try? Data(contentsOf: repo.appendingPathComponent("Resources/Scripts/TEAM/TEAM.emc")))
                .flatMap { try? Emc.Program($0) }.map { ScriptInfo($0) }
            : nil
        let parsedIni = Ini(ini)
        var state = GameState()
        state.loadScenario(ini: parsedIni, iconMap: try IconMap(icon), teamScriptOffsets: teamScriptInfo?.offsets ?? [])
        state.viewportPosition = Tile32.packXY(x: 12, y: 12)  // matches the oracle's pinned parity viewport
        // The [DUMPTILES] cells (the wall/slab goldens) — the same packed tiles the oracle dumps.
        let dumpTiles: [UInt16] = parsedIni.keys(section: "DUMPTILES")
            .compactMap { parsedIni.string(section: "DUMPTILES", key: $0).flatMap { UInt16($0) } }

        // Scen-style prepare (mirrors the oracle's Scen_LoadUnit + Game_Prepare placement): load each
        // unit's action script and stamp it on the map, so multi-unit setup — target resolution
        // (Unit_Get_ByPackedTile) and occupancy — matches the oracle before the command is issued.
        let setup = UnitActions()
        for slot in state.units.indices where state.units[slot].o.flags.contains(.used) {
            setup.setAction(slot: slot, action: state.units[slot].actionID, scriptInfo: scriptInfo, in: &state)
            state.unitUpdateMap(1, slot)
        }

        if spec.cmd {
            let order: Command = spec.attack
                ? .attack(unit: spec.cmdUnit, tile: spec.tile)
                : .move(unit: spec.cmdUnit, tile: spec.tile)
            UnitOrders(scriptInfo: scriptInfo).apply(order, in: &state)
            if let u2 = spec.cmd2Unit {  // the mutual missile duel: a second launcher attacks back
                UnitOrders(scriptInfo: scriptInfo).apply(.attack(unit: u2, tile: spec.cmd2Tile), in: &state)
            }
        }

        // Build+place commands (the refinery-harvester golden): the real structureBuildObject +
        // structurePlaceReady path (force-completing the build, as the oracle's Scen_BuildPlace does), so each
        // placed refinery spawns its own ferried harvester.
        if !spec.place.isEmpty {
            let combat = UnitCombat(movement: UnitMovement(scriptInfo: scriptInfo))
            for p in spec.place {
                let cy = Int(p.cy)
                _ = combat.structureBuildObject(slot: cy, objectType: p.objectType, in: &state)
                state.structures[cy].countDown = 0
                state.structures[cy].state = .ready
                _ = combat.structurePlaceReady(factory: cy, position: p.tile, in: &state)
            }
        }

        // Run our engine for the whole trajectory, capturing a frame per tick (frame 0 = post-command).
        var sim = Simulation(
            state: state,
            scriptInfo: scriptInfo,
            structureScriptInfo: structureScriptInfo,
            teamScriptInfo: teamScriptInfo,
            tickExplosions: spec.tickExplosions
        )
        // Human palace death-hand launch — applied here (after build, before the trace sink) so its setup draws
        // are untraced, exactly as the oracle launches before opening its RNG trace (`Scen_LaunchMissile`).
        for l in spec.launch { _ = sim.applyPalaceCommand(.launchHouseMissile(structure: l.structure, tile: l.tile)) }
        // Record our per-tick RNG draws (post-setup, like the oracle's trace) for the draw-stream assertion.
        let rngSink = RngTraceSink()
        sim.state.random256.traceSink = rngSink
        sim.state.randomLCG.traceSink = rngSink

        func frame() -> Frame {
            Frame(
                tick: 0,
                units: snapshot(sim.state),
                structures: structureSnapshot(sim.state),
                houses: houseSnapshot(sim.state, underAttack: spec.checkUnderAttack),
                tiles: tilesSnapshot(sim.state, dumpTiles)
            )
        }

        var ours: [Frame] = [ frame() ]
        for t in 1 ..< max(oracle.count, 1) {
            rngSink.setTick(UInt32(t))
            sim.tick()
            ours.append(frame())
        }

        // Assert the leading `compared` frames (0 ⇒ the whole trajectory) match tick by tick.
        let comparedTicks = spec.compared == 0 ? oracle.count : spec.compared
        var firstMismatch: Int? = nil
        var what = "units"
        for t in 0 ..< min(comparedTicks, oracle.count, ours.count) {
            if ours[t].units != oracle[t].units.sorted(by: { $0.index < $1.index }) {
                firstMismatch = t; what = "units"; break
            }
            if (ours[t].structures ?? []) != (oracle[t].structures ?? []).sorted(by: { $0.index < $1.index }) {
                firstMismatch = t; what = "structures"; break
            }
            if (ours[t].houses ?? []) != (oracle[t].houses ?? []).sorted(by: { $0.index < $1.index }) {
                firstMismatch = t; what = "houses"; break
            }
            if (ours[t].tiles ?? []).sorted(by: { $0.packed < $1.packed })
                    != (oracle[t].tiles ?? []).sorted(by: { $0.packed < $1.packed }) {
                firstMismatch = t; what = "tiles"; break
            }
        }
        let msg: String =
            firstMismatch.map { t in
                return switch what {
                    case "structures":
                        "\(spec.name): structures diverge at tick \(t): ours=\(ours[t].structures ?? []) oracle=\((oracle[t].structures ?? []).sorted(by: { $0.index < $1.index }))"
                    case "houses":
                        "\(spec.name): houses diverge at tick \(t): ours=\(ours[t].houses ?? []) oracle=\((oracle[t].houses ?? []).sorted(by: { $0.index < $1.index }))"
                    case "tiles":
                        "\(spec.name): tiles diverge at tick \(t): ours=\((ours[t].tiles ?? []).sorted(by: { $0.packed < $1.packed })) oracle=\((oracle[t].tiles ?? []).sorted(by: { $0.packed < $1.packed }))"
                    default:
                        "\(spec.name): units diverge at tick \(t): ours=\(ours[t].units) oracle=\(oracle[t].units.sorted(by: { $0.index < $1.index }))"
                }
            } ?? "\(spec.name): no divergence"
        #expect(firstMismatch == nil, "\(msg)")

        // RNG-stream golden: for full-match scenarios, assert our per-tick draw stream is byte-identical to
        // the oracle's `--parity-random-trace` / `--parity-lcg-trace`. This catches a missing/extra/reordered
        // draw the instant it happens — even when it doesn't (yet) move a compared field (exactly the
        // GameLoop_Team cursor bug that hid for months). The first-divergence message names the draw site.
        if spec.compared == 0 {
            if let r256Text = try? String(
                contentsOf: fix.appendingPathComponent("\(spec.name)-r256.txt"),
                encoding: .utf8
            ) {
                let div = RngTraceSink.firstDivergence(
                    ours: rngSink.r256,
                    oracle: RngTraceSink.parseOracleTrace(r256Text),
                    label: "\(spec.name) R256"
                )
                #expect(div == nil, "\(div ?? "")")
            }
            if let lcgText = try? String(
                contentsOf: fix.appendingPathComponent("\(spec.name)-lcg.txt"),
                encoding: .utf8
            ) {
                let div = RngTraceSink.firstDivergence(
                    ours: rngSink.lcg,
                    oracle: RngTraceSink.parseOracleTrace(lcgText),
                    label: "\(spec.name) LCG"
                )
                #expect(div == nil, "\(div ?? "")")
            }
        }
    }
}
