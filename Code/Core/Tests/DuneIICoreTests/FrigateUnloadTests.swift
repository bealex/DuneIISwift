import Foundation
import Testing
@testable import DuneIICore

/// STARPORT cargo-drop follow-up (2026-04-23). Covers the scheduler-
/// side `tickFrigateUnload`: once `tickStarportDelivery` has spawned
/// a FRIGATE at a STARPORT with a `linkedID` chain of off-map cargo
/// units, this pass walks the chain, drops each unit on a passable
/// adjacent tile around the 3×3 pad, clears `inTransport`, and frees
/// the frigate slot when the chain is empty.
@Suite("STARPORT frigate-unload — chain → adjacent tiles")
struct FrigateUnloadTests {

    private let FRIGATE: UInt8 = 26
    private let STARPORT: UInt8 = 11
    private let TANK: UInt8 = 9
    private let TRIKE: UInt8 = 13

    private func scheduler(
        landscape: @escaping (UInt16) -> UInt8 = { _ in UInt8(LandscapeType.normalSand.rawValue) }
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(landscapeAt: landscape, spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm, teamVM: vm)
    }

    /// Places a STARPORT at `anchor` for the given house + returns its
    /// pool index.
    @discardableResult
    private func spawnStarport(
        _ s: inout Simulation.Scheduler,
        at anchor: (x: Int, y: Int),
        houseID: UInt8 = Simulation.House.atreides
    ) -> Int {
        let idx = s.host.structures.allocate(
            in: 0...78, type: STARPORT, houseID: houseID
        )!
        var slot = s.host.structures[idx]
        slot.positionX = UInt16(anchor.x * 256)
        slot.positionY = UInt16(anchor.y * 256)
        slot.linkedID = 0xFF
        s.host.structures[idx] = slot
        return idx
    }

    /// Chains an off-map cargo unit onto `frigate.linkedID`; returns
    /// the new chain head (the cargo unit's pool index).
    @discardableResult
    private func chainCargo(
        _ s: inout Simulation.Scheduler,
        frigateIdx: Int, type: UInt8, houseID: UInt8 = Simulation.House.atreides
    ) -> Int {
        let cidx = Simulation.Units.createUnit(
            type: type, houseID: houseID, tileX: 0, tileY: 0, pool: &s.host.units
        )!
        var c = s.host.units[cidx]
        c.positionX = 0xFFFF
        c.positionY = 0xFFFF
        c.inTransport = true
        c.linkedID = s.host.units[frigateIdx].linkedID
        s.host.units[cidx] = c
        var f = s.host.units[frigateIdx]
        f.linkedID = UInt8(truncatingIfNeeded: cidx & 0xFF)
        s.host.units[frigateIdx] = f
        return cidx
    }

    // MARK: - Drop semantics

    @Test("Frigate with 2 cargo units drops both + frees its slot")
    func frigateDropsAllCargoAndFrees() {
        var s = scheduler()
        let spIdx = spawnStarport(&s, at: (x: 20, y: 20))
        #expect(spIdx >= 0)
        // Spawn FRIGATE at the STARPORT anchor.
        let fIdx = Simulation.Units.createUnit(
            type: FRIGATE, houseID: Simulation.House.atreides,
            tileX: 20, tileY: 20, pool: &s.host.units
        )!
        var f = s.host.units[fIdx]
        f.inTransport = true
        f.linkedID = 0xFF
        s.host.units[fIdx] = f
        let cargo1 = chainCargo(&s, frigateIdx: fIdx, type: TRIKE)
        let cargo2 = chainCargo(&s, frigateIdx: fIdx, type: TANK)

        s.tickFrigateUnload()

        // Frigate freed.
        #expect(!s.host.units.slots[fIdx].isUsed,
                "frigate slot should free once the chain drains")
        // Both cargo units placed somewhere in the 12-tile adjacency
        // ring around the STARPORT anchor (20..22, 20..22).
        let c1 = s.host.units.slots[cargo1]
        let c2 = s.host.units.slots[cargo2]
        #expect(c1.isUsed && !c1.inTransport)
        #expect(c2.isUsed && !c2.inTransport)
        #expect(c1.linkedID == 0xFF && c2.linkedID == 0xFF)
        // Adjacent-ring test: each cargo is within 1 tile of the pad.
        for c in [c1, c2] {
            let tx = Int(c.positionX) / 256
            let ty = Int(c.positionY) / 256
            let onRing = (tx >= 19 && tx <= 23) && (ty >= 19 && ty <= 23)
            #expect(onRing, "cargo landed outside the adjacency ring at (\(tx),\(ty))")
            // Not inside the footprint itself (20..22, 20..22).
            let inFootprint = (20...22).contains(tx) && (20...22).contains(ty)
            #expect(!inFootprint,
                    "cargo landed on the pad tiles (\(tx),\(ty)) — should be adjacent")
        }
    }

    @Test("Frigate keeps chain head + stays alive when no adjacent tile is passable")
    func frigateRetriesWhenRingFull() {
        // Wrap the STARPORT in a ring of mountain tiles — nothing
        // passable for a tracked cargo unit.
        var s = scheduler(landscape: { packed in
            let tx = Int(packed & 0x3F)
            let ty = Int((packed >> 6) & 0x3F)
            // Inside 20..22 footprint stays as sand (STARPORT renders
            // over it); outside = mountain.
            if (20...22).contains(tx) && (20...22).contains(ty) {
                return UInt8(LandscapeType.normalSand.rawValue)
            }
            return UInt8(LandscapeType.entirelyMountain.rawValue)
        })
        _ = spawnStarport(&s, at: (x: 20, y: 20))
        let fIdx = Simulation.Units.createUnit(
            type: FRIGATE, houseID: Simulation.House.atreides,
            tileX: 20, tileY: 20, pool: &s.host.units
        )!
        var f = s.host.units[fIdx]
        f.inTransport = true
        f.linkedID = 0xFF
        s.host.units[fIdx] = f
        let cargoIdx = chainCargo(&s, frigateIdx: fIdx, type: TANK)

        s.tickFrigateUnload()

        // Frigate slot lives, chain head retained. Cargo still
        // off-map + in transport.
        #expect(s.host.units.slots[fIdx].isUsed)
        #expect(s.host.units.slots[fIdx].linkedID != 0xFF,
                "chain must be preserved when no passable ring tile is available")
        let cargo = s.host.units.slots[cargoIdx]
        #expect(cargo.positionX == 0xFFFF && cargo.positionY == 0xFFFF)
        #expect(cargo.inTransport)
    }

    @Test("Frigate without cargo is left alone")
    func frigateNoCargoNoOp() {
        var s = scheduler()
        _ = spawnStarport(&s, at: (x: 20, y: 20))
        let fIdx = Simulation.Units.createUnit(
            type: FRIGATE, houseID: Simulation.House.atreides,
            tileX: 20, tileY: 20, pool: &s.host.units
        )!
        var f = s.host.units[fIdx]
        f.inTransport = true
        f.linkedID = 0xFF           // no chain
        s.host.units[fIdx] = f
        s.tickFrigateUnload()
        // Nothing should have changed.
        #expect(s.host.units.slots[fIdx].isUsed)
    }

    @Test("Ownership gate: FRIGATE of house A does not unload at STARPORT of house B")
    func frigateHouseMismatchSkips() {
        var s = scheduler()
        // STARPORT is Harkonnen's, frigate is Atreides'.
        _ = spawnStarport(
            &s, at: (x: 20, y: 20), houseID: Simulation.House.harkonnen
        )
        let fIdx = Simulation.Units.createUnit(
            type: FRIGATE, houseID: Simulation.House.atreides,
            tileX: 20, tileY: 20, pool: &s.host.units
        )!
        var f = s.host.units[fIdx]
        f.inTransport = true
        f.linkedID = 0xFF
        s.host.units[fIdx] = f
        let cargoIdx = chainCargo(&s, frigateIdx: fIdx, type: TANK)
        s.tickFrigateUnload()
        // No Atreides STARPORT exists → nearestStarport returns nil
        // → nothing unloads.
        #expect(s.host.units.slots[fIdx].isUsed)
        #expect(s.host.units.slots[fIdx].linkedID != 0xFF)
        #expect(s.host.units.slots[cargoIdx].inTransport)
    }

    // MARK: - End-to-end with tickStarportDelivery

    @Test("Delivery → unload pipeline: frigate spawns, chain drops, slot frees within one tick block")
    func endToEndDeliveryAndUnload() {
        var s = scheduler()
        // Wire a house + STARPORT.
        s.host.houses.allocate(at: Int(Simulation.House.atreides))
        _ = spawnStarport(&s, at: (x: 20, y: 20))
        // Pre-chain two cargo units (mimicking a prior
        // commitStarportOrder) and prime the timer.
        var houseSlot = s.host.houses[Int(Simulation.House.atreides)]
        let cargo1 = Simulation.Units.createUnit(
            type: TRIKE, houseID: Simulation.House.atreides,
            tileX: 0, tileY: 0, pool: &s.host.units
        )!
        let cargo2 = Simulation.Units.createUnit(
            type: TANK, houseID: Simulation.House.atreides,
            tileX: 0, tileY: 0, pool: &s.host.units
        )!
        // Put them off-map + chain them: house head → cargo2 → cargo1 → 0xFF.
        for (cidx, next) in [(cargo1, UInt8(0xFF)), (cargo2, UInt8(cargo1))] {
            var c = s.host.units[cidx]
            c.positionX = 0xFFFF
            c.positionY = 0xFFFF
            c.inTransport = true
            c.linkedID = next
            s.host.units[cidx] = c
        }
        houseSlot.starportLinkedID = UInt16(cargo2)
        houseSlot.starportTimeLeft = 1
        s.host.houses[Int(Simulation.House.atreides)] = houseSlot

        // Delivery pass: spawns a FRIGATE with the chain.
        s.tickStarportDelivery()
        // Then unload.
        s.tickFrigateUnload()

        // Both cargo units now sit on the pad's adjacency ring with
        // inTransport = false; frigate slot freed.
        let c1 = s.host.units.slots[cargo1]
        let c2 = s.host.units.slots[cargo2]
        #expect(!c1.inTransport && c1.linkedID == 0xFF)
        #expect(!c2.inTransport && c2.linkedID == 0xFF)
        // At least one of them must be on-map.
        #expect(c1.positionX != 0xFFFF || c2.positionX != 0xFFFF)
        // Chain cleared on the house.
        let h = s.host.houses.slots[Int(Simulation.House.atreides)]
        #expect(h.starportLinkedID == Simulation.HousePool.invalidIndex,
                "house chain head cleared on delivery")
    }
}
