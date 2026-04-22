import Foundation

extension Simulation {
    /// Spice-bloom handling. A non-sandworm unit stepping on a bloom
    /// tile triggers `explodeSpice`: the bloom detonates into a
    /// spice-filling explosion, removing the walking unit and
    /// scattering spice on a circular area around the blast.
    ///
    /// Port of OpenDUNE `Map_Bloom_ExplodeSpice` + `Map_FillCircleWithSpice`
    /// (`src/map.c:669` and `:697`). Special-bloom variant
    /// (`Map_Bloom_ExplodeSpecial`) is deferred.
    public enum Bloom {
        /// Radius of the spice-fill circle around the detonation.
        /// OpenDUNE hard-codes 5; same here.
        public static let spiceFillRadius: Int = 5

        /// Detonate a spice bloom at `packed` triggered by `unitIndex`:
        ///
        /// 1. Spawn an `EXPLOSION_SPICE_BLOOM_TREMOR` at the tile (via
        ///    `Explosions.makeExplosion` — no radius damage, cosmetic).
        /// 2. Reset the cell's `groundTileID` to sand (`sandTileID`).
        ///    Caller supplies the sand tile ID since it's resolver-
        ///    dependent; `host.groundTileOverride` does the write.
        /// 3. Fill a 5-tile-radius circle with spice via
        ///    `spiceMap.apply(+1, at:)` on every cell that isn't
        ///    already spice or thick. Edge cells (`distance == radius`)
        ///    are accepted 50% of the time — consumes one RNG byte
        ///    per edge cell, matching OpenDUNE.
        /// 4. Free the walking unit (removes it from the map).
        ///
        /// Preconditions: `unitIndex` is valid; caller has already
        /// verified the unit is non-sandworm + on a bloom tile.
        public static func explodeSpice(
            packed: UInt16,
            unitIndex: Int,
            sandTileID: UInt16,
            host: Scripting.Host,
            rng: () -> UInt8
        ) {
            let houseID: UInt8 = (unitIndex < host.units.slots.count)
                ? host.units.slots[unitIndex].houseID
                : 0
            let centerX = Int(packed & 0x3F)
            let centerY = Int((packed >> 6) & 0x3F)
            let centerPos = Pos32(
                x: UInt16(clamping: centerX * 256 + 128),
                y: UInt16(clamping: centerY * 256 + 128)
            )

            // 1. Explosion visual (no radius damage — bloom damage is
            //    handled by freeing the walking unit in step 4).
            Explosions.makeExplosion(
                type: ExplosionType.spiceBloomTremor.rawValue,
                position: centerPos,
                hitpoints: 0,
                unitOriginEncoded: 0,
                host: host
            )

            // 2. Reset the bloom tile's ground sprite to sand.
            host.groundTileOverride?(packed, sandTileID)

            // 3. Fill spice circle (skip the centre — it's the bloom
            //    tile we just reset; OpenDUNE's `Map_FillCircleWithSpice`
            //    applies +1 to the centre at the end but only if it's
            //    already sand, and the skipped-if-spice gate means the
            //    centre's new "sand" state takes the apply).
            if var map = host.spiceMap {
                let radius = spiceFillRadius
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let tx = centerX + dx
                        let ty = centerY + dy
                        guard (0..<64).contains(tx), (0..<64).contains(ty) else { continue }
                        let distance = max(abs(dx), abs(dy))
                             + min(abs(dx), abs(dy)) / 2
                        if distance > radius { continue }
                        if distance == radius, (rng() & 1) == 0 { continue }
                        let cp = UInt16(ty * 64 + tx)
                        // Skip cells that can't host more spice.
                        let level = map[cp]
                        if level == .thick || level == .notSand { continue }
                        let before = level
                        let after = map.apply(delta: +1, at: cp)
                        if before != after {
                            host.spiceLevelDidChange?(cp, after)
                        }
                    }
                }
                host.spiceMap = map
            }
            // Apply once more at the centre so it becomes a spice tile
            // rather than bare sand — matches `Map_FillCircleWithSpice`
            // tail `Map_ChangeSpiceAmount(packed, 1)`.
            if var map = host.spiceMap {
                let levelBefore = map[packed]
                let levelAfter = map.apply(delta: +1, at: packed)
                if levelBefore != levelAfter {
                    host.spiceLevelDidChange?(packed, levelAfter)
                }
                host.spiceMap = map
            }

            // 4. Free the walking unit.
            if unitIndex >= 0, unitIndex < host.units.slots.count,
               host.units.slots[unitIndex].isUsed
            {
                host.units.free(at: unitIndex)
            }

            Log.info(
                "bloom-explode tile=(\(centerX),\(centerY)) triggeredBy=unit=\(unitIndex) house=\(houseID)",
                tracer: .label("bloom")
            )
        }
    }
}
