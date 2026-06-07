import DuneIIContracts
import DuneIIFormats
import Foundation
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// Palace special-weapon body — `Structure_ActivateSpecial` (`structure.c:822`) fired by the palace cursor in
/// `GameLoop_Structure` when an AI palace's countdown hits zero. Each house's `specialWeapon` differs:
/// Harkonnen/Sardaukar launch a death-hand missile, Atreides/Fremen call 5 Fremen, Ordos/Mercenary deploy a
/// saboteur. A fresh palace starts at `countDown == 0`, so an AI one fires on its first palace tick.
@Suite("Palace special weapon")
struct PalaceTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func addPalace(_ s: inout GameState, house: UInt8) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.palace.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = StructureInfo[.palace].o.hitpoints
        s.structures[slot].o.position = Tile32.unpack(Tile32.packXY(x: 32, y: 32))
        s.structures[slot].countDown = 0
        return slot
    }

    private func countUnits(_ s: inout GameState, type: UnitType, house: UInt8? = nil) -> Int {
        var find = PoolFind(houseID: house ?? Pool.houseInvalid, type: UInt16(type.rawValue))
        var n = 0
        while s.unitFind(&find) != nil { n += 1 }
        return n
    }

    @Test("AI Harkonnen palace launches a death-hand missile at the player's structure")
    func missile() {
        var s = GameState(); s.playerHouseID = 1
        _ = s.houseAllocate(index: 0); s.houses[0].flags.insert(.isAIActive); s.houses[0].unitCountMax = 100
        _ = s.houseAllocate(index: 1)
        let palace = addPalace(&s, house: 0)
        let target = s.structureAllocate(
            index: Pool.structureIndexInvalid,
            type: UInt8(StructureType.windtrap.rawValue)
        )!
        s.structures[target].o.houseID = 1  // the player's structure — not allied with the AI
        s.structures[target].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.structureActivateSpecial(palace)
        // The carrier is created then freed; the launched death-hand bullet (also `missileHouse`) remains.
        #expect(countUnits(&sm.state, type: .missileHouse) == 1)
        #expect(sm.state.structures[palace].countDown == HouseInfo[.harkonnen].specialCountDown)
    }

    @Test("AI Atreides palace calls 5 Fremen and re-arms the countdown")
    func fremen() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 1); s.houses[1].flags.insert(.isAIActive)
        _ = s.houseAllocate(index: 3); s.houses[3].unitCountMax = 100  // HOUSE_FREMEN owns the spawned troopers
        let palace = addPalace(&s, house: 1)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.structureActivateSpecial(palace)
        // Up to 5 — the clustered spawns can collide (`Unit_Create` returns nil on an occupied tile, as in
        // OpenDUNE), so the faithful outcome is 5 minus any overlaps.
        let fremen = countUnits(&sm.state, type: .trooper) + countUnits(&sm.state, type: .troopers)
        #expect((4 ... 5).contains(fremen))
        #expect(sm.state.structures[palace].countDown == HouseInfo[.atreides].specialCountDown)
    }

    @Test("AI Ordos palace deploys a saboteur next to the palace")
    func saboteur() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 2); s.houses[2].flags.insert(.isAIActive); s.houses[2].unitCountMax = 100
        let palace = addPalace(&s, house: 2)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.structureActivateSpecial(palace)
        #expect(countUnits(&sm.state, type: .saboteur, house: 2) == 1)
        #expect(sm.state.structures[palace].countDown == HouseInfo[.ordos].specialCountDown)
    }

    @Test("human launch: a death-hand missile fires at the player's chosen tile")
    func humanMissile() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].flags.insert(.human); s.houses[0].unitCountMax = 100
        let palace = addPalace(&s, house: 0)  // player-owned Harkonnen palace, ready (countDown 0)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        let handled = sm.applyPalaceCommand(
            .launchHouseMissile(
                structure: UInt16(palace),
                tile: Tile32.packXY(x: 12, y: 40)
            )
        )
        #expect(handled)
        #expect(countUnits(&sm.state, type: .missileHouse) == 1)  // the launched death-hand bullet
        #expect(sm.state.structures[palace].countDown == HouseInfo[.harkonnen].specialCountDown)
    }

    @Test("human launch: an Atreides palace activates the Fremen call (no target)")
    func humanFremen() {
        var s = GameState(); s.playerHouseID = 1
        _ = s.houseAllocate(index: 1); s.houses[1].flags.insert(.human)  // player-owned Atreides palace
        _ = s.houseAllocate(index: 3); s.houses[3].unitCountMax = 100  // HOUSE_FREMEN owns the troopers
        let palace = addPalace(&s, house: 1)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        let handled = sm.applyPalaceCommand(.activateSuperWeapon(structure: UInt16(palace)))
        #expect(handled)
        let fremen = countUnits(&sm.state, type: .trooper) + countUnits(&sm.state, type: .troopers)
        #expect((4 ... 5).contains(fremen))
        #expect(sm.state.structures[palace].countDown == HouseInfo[.atreides].specialCountDown)
    }

    @Test("Fremen call spawns even when the Fremen house isn't a scenario house (unit cap 0)")
    func fremenWithoutAllocatedFremenHouse() {
        var s = GameState(); s.playerHouseID = 1
        s.enforceUnitLimit = true  // the in-game default — the condition that exposed the bug
        _ = s.houseAllocate(index: 1); s.houses[1].flags.insert(.human)  // Atreides palace owner
        // Deliberately do NOT allocate HOUSE_FREMEN (3): in a real scenario it isn't a house, so its
        // `unitCountMax` is 0 and `Unit_Allocate` would refuse the foot soldiers — unless the create is wrapped
        // in the `validateStrictIfZero` bypass (as OpenDUNE does, and now we do). Without the fix this is 0.
        let palace = addPalace(&s, house: 1)

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        let handled = sm.applyPalaceCommand(.activateSuperWeapon(structure: UInt16(palace)))
        #expect(handled)
        let fremen = countUnits(&sm.state, type: .trooper) + countUnits(&sm.state, type: .troopers)
        #expect(fremen >= 1, "Fremen must appear even though the Fremen house has no unit-cap allocation")
    }

    @Test("human launch gating: no fire when not ready, enemy-owned, or non-super-weapon command")
    func humanLaunchGating() {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].flags.insert(.human); s.houses[0].unitCountMax = 100
        _ = s.houseAllocate(index: 1); s.houses[1].unitCountMax = 100  // enemy
        let notReady = addPalace(&s, house: 0);  // player Harkonnen palace, recharging
        let enemy = addPalace(&s, house: 1)  // enemy palace, ready

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.state.structures[notReady].countDown = 5  // still recharging ⇒ must not fire

        let firedNotReady = sm.applyPalaceCommand(
            .launchHouseMissile(
                structure: UInt16(notReady),
                tile: Tile32.packXY(x: 12, y: 40)
            )
        )
        let firedEnemy = sm.applyPalaceCommand(.activateSuperWeapon(structure: UInt16(enemy)))
        #expect(firedNotReady)  // consumed…
        #expect(firedEnemy)  // …consumed…
        #expect(countUnits(&sm.state, type: .missileHouse) == 0)  // …but nothing fired
        #expect(sm.state.structures[notReady].countDown == 5)

        // A non-super-weapon command is not consumed here (the caller routes it through UnitOrders).
        let notConsumed = sm.applyPalaceCommand(.stop(unit: 0))
        #expect(!notConsumed)
    }

    @Test("loaded scenario: a Brain=Human player's palace does not auto-fire at start (castle-rocket bug)")
    func loadedHumanPalaceDoesNotAutoFire() throws {
        // End-to-end repro of "the Harkonnen castle launches a rocket when the scenario starts": load a
        // scenario through the real loader (which must now set flags.human), then run the palace cursor.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        guard
            let iconData = try? Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP"))
        else {
            return
        }

        let iconMap = try IconMap(iconData)
        // A Harkonnen (Brain=Human) palace + an Ordos target. The [TEAMS] entry flips Harkonnen isAIActive —
        // the *other* half of the `!human && isAIActive` auto-fire gate — so only the human flag stops the launch.
        let iniText = """
            [BASIC]
            MapScale=1
            [Harkonnen]
            Brain=Human
            Credits=1000
            [Ordos]
            Brain=CPU
            [MAP]
            Seed=4660
            [STRUCTURES]
            ID000=Harkonnen,Palace,256,1040
            ID001=Ordos,Windtrap,256,1300
            [TEAMS]
            ID000=Harkonnen,Normal,Foot,1,1
            """
        var state = GameState()
        state.loadScenario(ini: Ini(Data(iniText.utf8)), iconMap: iconMap)
        let player = Int(state.playerHouseID)
        #expect(state.houses[player].flags.contains(.human))  // the fix
        #expect(state.houses[player].flags.contains(.isAIActive))  // the gate's other half (via [TEAMS])
        let palace = try #require(
            state.structures.firstIndex {
                $0.o.flags.contains(.used) && $0.o.type == UInt8(StructureType.palace.rawValue)
            }
        )
        #expect(state.structures[palace].countDown == 0)  // a fresh palace is "ready"

        // Fire only the palace cursor (as in `loopFiresAIOnly`).
        func armPalaceCursorOnly(_ s: inout GameState) {
            s.timerGame = 20000
            s.structureTick.palace = 0
            s.structureTick.structure = 30000; s.structureTick.script = 30000; s.structureTick.degrade = 30000
        }

        armPalaceCursorOnly(&state)

        var sm = Simulation(state: state, scriptInfo: info, structureScriptInfo: info)
        sm.gameLoopStructure()
        #expect(sm.state.structures[palace].countDown == 0)  // human palace did NOT fire
        #expect(countUnits(&sm.state, type: .missileHouse) == 0)  // no rocket launched at start

        // Negative control: the pre-fix state (human flag missing) ⇒ the same palace DOES auto-fire its
        // death-hand at the Ordos target on its first palace tick — exactly the reported bug.
        var state2 = state
        state2.houses[player].flags.remove(.human)
        var sm2 = Simulation(state: state2, scriptInfo: info, structureScriptInfo: info)
        sm2.gameLoopStructure()
        #expect(sm2.state.structures[palace].countDown == HouseInfo[.harkonnen].specialCountDown)  // fired
        #expect(countUnits(&sm2.state, type: .missileHouse) == 1)  // rocket launched
    }

    @Test("via the loop: an AI palace fires on its first palace tick; a human palace does not")
    func loopFiresAIOnly() {
        var s = GameState(); s.playerHouseID = 1
        _ = s.houseAllocate(index: 0); s.houses[0].flags.insert(.isAIActive); s.houses[0].unitCountMax = 100
        _ = s.houseAllocate(index: 1); s.houses[1].flags = [ .used, .human, .isAIActive ]
        let ai = addPalace(&s, house: 0)
        let human = addPalace(&s, house: 1)
        let target = s.structureAllocate(
            index: Pool.structureIndexInvalid,
            type: UInt8(StructureType.windtrap.rawValue)
        )!
        s.structures[target].o.houseID = 1
        s.structures[target].o.position = Tile32.unpack(Tile32.packXY(x: 10, y: 10))
        // Fire only the palace cursor this tick.
        s.timerGame = 20000
        s.structureTick.palace = 0
        s.structureTick.structure = 30000; s.structureTick.script = 30000; s.structureTick.degrade = 30000

        var sm = Simulation(state: s, scriptInfo: info, structureScriptInfo: info)
        sm.gameLoopStructure()
        #expect(sm.state.structures[ai].countDown == HouseInfo[.harkonnen].specialCountDown)  // AI fired
        #expect(sm.state.structures[human].countDown == 0)  // human did not
    }
}
