import DuneIIContracts
import DuneIIWorld

extension Simulation {
    /// The `GameLoop_House` reinforcement block (`house.c:118`): once per 600-tick reinforcement cursor,
    /// count each loaded `[REINFORCEMENTS]` entry down and deploy it at zero.
    ///
    /// - An **edge** entry (`locationID` 0-3 = N/E/S/W) places the unit directly at a random tile on that
    ///   map edge (the original `Unit_SetPosition` of a pre-created off-map unit).
    /// - An **air** entry (4-7 = AIR/VISIBLE/ENEMYBASE/HOMEBASE) dispatches a carryall from a random edge to
    ///   drop the unit at the resolved location (`Unit_CreateWrapper` → spawn carryall + cargo, link, fly).
    ///
    /// 1.07 (non-enhanced, our oracle) never repeats — `Reinforcement.repeats` is pinned `false` — so each
    /// entry fires exactly once; we mark it empty on a successful deploy. We create the unit at deploy time
    /// (the unit cap is bypassed, as the original bypasses it when it pre-creates the unit at scenario load).
    /// A failed deploy (occupied tile / pool full) re-arms `timeLeft = 1` to retry on the next cursor.
    mutating func tickReinforcements() {
        guard let combat = unitScript?.combat else { return }   // needs the unit layer to spawn

        for i in state.scenario.reinforcements.indices {
            if state.scenario.reinforcements[i].isEmpty { continue }
            if state.scenario.reinforcements[i].timeLeft == 0 { continue }
            state.scenario.reinforcements[i].timeLeft &-= 1
            if state.scenario.reinforcements[i].timeLeft != 0 { continue }

            let r = state.scenario.reinforcements[i]
            var deployed = false

            if r.locationID >= 4 {
                let tile = mapPrimitives.findLocationTile(UInt16(r.locationID), houseID: r.houseID, in: &state)
                let destination = state.indexEncode(tile, type: .tile)
                if let type = UnitType(rawValue: Int(r.unitType)),
                   combat.unitCreateWrapper(houseID: r.houseID, type: type, destination: destination, in: &state) != nil {
                    deployed = true
                }
            } else {
                let tile = Tile32.unpack(mapPrimitives.findLocationTile(UInt16(r.locationID), houseID: r.houseID, in: &state))
                state.validateStrictIfZero &+= 1
                let slot = combat.unitCreate(index: Pool.unitIndexInvalid, type: r.unitType, houseID: r.houseID,
                                             position: tile, orientation: 0, in: &state)
                state.validateStrictIfZero &-= 1
                deployed = slot != nil
            }

            if deployed {
                state.scenario.reinforcements[i].unitType = 0xFF   // consumed (1.07 never repeats)
            } else {
                state.scenario.reinforcements[i].timeLeft = 1      // retry next cursor
            }
        }
    }
}
