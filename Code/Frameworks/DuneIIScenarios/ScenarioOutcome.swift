import DuneIIContracts
import DuneIIWorld

/// Whether a scenario has reached its natural endpoint, with a short label for the lab's "done" marker.
public enum ScenarioOutcome: Sendable, Equatable {
    case running
    case finished(String)
}

public extension ScenarioWorld {
    /// The scenario's terminal state — `running` until its natural endpoint, then `finished(label)`.
    ///
    /// This is a **visual-harness affordance**, not a simulation victory model: the lab just needs to know
    /// when there's nothing more to watch (a unit arrived, a building was destroyed/built/repaired/upgraded,
    /// a combatant died, a unit was deviated). The simulation models no game-over; each `ScenarioKind` here
    /// declares its own natural endpoint so `scenariolab` can flag it.
    func outcome() -> ScenarioOutcome {
        func unitUsed(_ slot: Int) -> Bool { state.units[slot].o.flags.contains(.used) }
        func structUsed(_ slot: Int) -> Bool { state.structures[slot].o.flags.contains(.used) }
        // A moving unit is "arrived" once its position packs to the destination tile.
        func arrived(_ slot: Int, _ lx: Int, _ ly: Int) -> Bool {
            unitUsed(slot) && state.units[slot].o.position.packed == terrain.mapPacked(lx: lx, ly: ly)
        }

        switch kind {
            case .moving, .moveAroundBuilding:
                if arrived(unitSlots[0], 7, 7) { return .finished("Reached destination") }

            case .closeAttack, .farAttack:
                if unitSlots.contains(where: { !unitUsed($0) }) { return .finished("A unit was destroyed") }

            case .guarding:
                if unitSlots.contains(where: { !unitUsed($0) }) { return .finished("A unit was destroyed") }
                if arrived(unitSlots[1], 2, 2) { return .finished("Crossed to the guard") }

            case .deviate:
                if state.units[unitSlots[0]].deviated != 0 { return .finished("Unit deviated") }

            case .attackStructure:
                if let s = structureSlots.first, !structUsed(s) { return .finished("Building destroyed") }

            case .turretDefense:
                if unitSlots.contains(where: { !unitUsed($0) }) { return .finished("Attacker destroyed") }

            case .factoryProduce:
                if let s = structureSlots.first, state.structures[s].state == .ready {
                    return .finished("Unit built (READY)")
                }

            case .repairBuilding:
                if let s = structureSlots.first,
                    let type = StructureType(rawValue: Int(state.structures[s].o.type)),
                    state.structures[s].o.hitpoints >= StructureInfo[type].o.hitpoints
                {
                    return .finished("Repaired to full HP")
                }

            case .upgradeBuilding:
                if let s = structureSlots.first, state.structures[s].upgradeLevel >= 1 {
                    return .finished("Upgraded to level 1")
                }

            case .sandwormEating:
                // unitSlots = [worm, prey]; the prey is removed when swallowed.
                if unitSlots.count > 1, !unitUsed(unitSlots[1]) { return .finished("Unit devoured") }
        }
        return .running
    }
}
