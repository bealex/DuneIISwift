import Foundation
import SpriteKit
import DuneIICore

/// Concatenated unit-sprite atlas matching OpenDUNE's `g_sprites[]`
/// numbering at `src/sprites.c:487..494`. We skip MOUSE / BTTN / SHAPES
/// (not used by units) and load the three unit-bearing SHPs in the same
/// order + sprite-index layout the C engine uses:
///
/// | Global index | Source | Comment |
/// |---|---|---|
/// | 111..150 | `UNITS2.SHP` (40 frames) | Heavy armour: tank, siege, devastator, sonic |
/// | 151..237 | `UNITS1.SHP` (87 frames) | Sandworm, soldiers, …|
/// | 238..354 | `UNITS.SHP` (117 frames) | Light + infantry + MCV |
///
/// Indices below 111 or above 354 are not unit sprites — we store `nil`
/// in those slots so `texture(at:)` returns `nil` rather than trap.
@MainActor
public final class UnitSpriteAtlas {
    /// Total slots covered. Matches `g_sprites` in size up through UNITS.SHP.
    public static let count = 355

    /// Per-house texture caches, keyed by houseID (0..5). A slot's
    /// nil entry means "no sprite at this global ID for this house".
    /// Lazy — a house's variant is built on first lookup, not eagerly,
    /// so scenarios that only expose two houses don't pay the cost of
    /// six full atlas decodes.
    private var perHouse: [UInt8: [SKTexture?]] = [:]
    private let loader: AssetLoader

    public init(loader: AssetLoader) throws {
        self.loader = loader
        // Pre-build house 0 (Harkonnen / default) so tests and early
        // code paths that don't care about per-house tint still work.
        perHouse[0] = try Self.buildTextures(houseID: 0, loader: loader)
    }

    public func texture(at spriteID: Int, houseID: UInt8 = 0) -> SKTexture? {
        if perHouse[houseID] == nil {
            // Lazy-build on first miss. Any decode failure fails silently
            // and leaves the slot empty so the fallback marker renders.
            perHouse[houseID] = (try? Self.buildTextures(houseID: houseID, loader: loader)) ??
                [SKTexture?](repeating: nil, count: Self.count)
        }
        guard let slots = perHouse[houseID],
              spriteID >= 0, spriteID < slots.count else { return nil }
        return slots[spriteID]
    }

    /// Compose the ground-frame sprite index for a unit at an arbitrary
    /// 0..255 orientation, according to `values_32A4` and the unit's
    /// `displayMode`. Returns `(spriteID, flipHorizontal)`. Pure
    /// computation — safe to call off the main actor.
    public nonisolated static func resolveFrame(
        info: Simulation.UnitInfo,
        orientation: Int8
    ) -> (spriteID: Int, flipHorizontal: Bool) {
        let octant = Orientation.to8(orientation)
        let frame = Orientation.octantFrame[Int(octant)]
        switch info.displayMode {
        case .unit, .rocket, .ornithopter:
            // SLITHER (sandworm) skips the orientation offset.
            if info.movementType == .slither {
                return (Int(info.groundSpriteID), false)
            }
            return (Int(info.groundSpriteID) + Int(frame.offset), frame.flipHorizontal)
        case .infantry3, .infantry4:
            // 3/4-frame walk cycles stride by 3 or 4 per orientation bucket.
            // MVP: always pick the "idle" frame at offset 0.
            let stride = info.displayMode == .infantry3 ? 3 : 4
            // `values_32C4` in OpenDUNE has only 3 distinct frames (0, 1, 2);
            // re-use the octant frame as the bucket since both tables share
            // the odd-octant mirroring pattern. See viewport.c:511.
            let bucket = min(Int(frame.offset), 2)
            return (Int(info.groundSpriteID) + bucket * stride, frame.flipHorizontal)
        case .singleFrame:
            return (Int(info.groundSpriteID), false)
        }
    }

    // MARK: - Private

    private static func buildTextures(
        houseID: UInt8, loader: AssetLoader
    ) throws -> [SKTexture?] {
        var slots = [SKTexture?](repeating: nil, count: Self.count)
        try fill(into: &slots, at: 111, from: "UNITS2.SHP", houseID: houseID, loader: loader)
        try fill(into: &slots, at: 151, from: "UNITS1.SHP", houseID: houseID, loader: loader)
        try fill(into: &slots, at: 238, from: "UNITS.SHP",  houseID: houseID, loader: loader)
        return slots
    }

    private static func fill(
        into slots: inout [SKTexture?], at baseID: Int,
        from shpName: String, houseID: UInt8, loader: AssetLoader
    ) throws {
        let frames = try loader.loadShp(named: shpName, houseID: houseID)
        for (i, cg) in frames.enumerated() {
            let slot = baseID + i
            guard slot < slots.count else { break }
            let tx = SKTexture(cgImage: cg)
            tx.filteringMode = .nearest
            slots[slot] = tx
        }
    }
}
