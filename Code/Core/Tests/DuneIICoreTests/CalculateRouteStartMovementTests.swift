import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Script_Unit_CalculateRoute`'s inlined
/// `Unit_StartMovement` slice (port of `src/unit.c:1088..1105`):
///
/// - **LST_STRUCTURE → LST_CONCRETE_SLAB remap for movementSpeed**
///   (`src/unit.c:1088..1089`): a foot unit walking across a friendly
///   / enemy structure tile reads concrete-slab speed (255) instead
///   of the 0 entry in LST_STRUCTURE's row — without this every
///   HUNT unit heading into a structure clamps to speed 0 and never
///   reaches the target.
///
/// - **`isWobbling = letUnitWobble` enhanced clear**
///   (`src/unit.c:1097..1101`): OpenDUNE's `g_dune2_enhanced` path
///   overwrites `isWobbling` every step, so a canWobble unit that
///   walks off rock onto sand stops wobbling. Without the clear,
///   `Tools_Random_256` drifts by one byte per step on every
///   canWobble unit after it leaves rock.
@Suite("CalculateRoute — StartMovement slice (speed + wobble)")
struct CalculateRouteStartMovementTests {

    private static let SOLDIER: UInt8 = 4

    /// Build a minimal host with one SOLDIER placed at tile (10, 10)
    /// with `route[0] = 1` (step NE) + a landscape oracle the caller
    /// can customise so the next-tile landscape can be pinned.
    private static func makeHost(nextLandscape: LandscapeType) -> Scripting.Host {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: SOLDIER, houseID: 1)
        var u = units[0]
        u.positionX = 10 * 256 + 128
        u.positionY = 10 * 256 + 128
        u.route = [UInt8](repeating: 0xFF, count: 14)
        u.route[0] = 1  // step NE
        // Pre-orient so CalculateRoute's orientation gate passes and
        // the setSpeed block runs this call.
        u.orientationCurrent = 32
        u.orientationTarget = 32
        u.orientationSpeed = 0
        u.targetMove = Scripting.EncodedIndex.tile(packed: 9 &* 64 + 11).raw
        u.isWobbling = true  // pre-set so the clear is observable
        u.hitpoints = 20
        units[0] = u

        let host = Scripting.Host(
            units: units, structures: Simulation.StructurePool(),
            currentObject: .unit(poolIndex: 0),
            texts: [], textLog: [], voiceLog: []
        )
        host.landscapeAt = { _ in UInt8(nextLandscape.rawValue) }
        return host
    }

    @Test("LST_STRUCTURE landscape remaps to LST_CONCRETE_SLAB → foot speed 255 (src/unit.c:1088..1089)")
    func structureRemapsToConcreteSlabSpeed() throws {
        let host = Self.makeHost(nextLandscape: .structure)
        let source = Scripting.RandomSource(lcgSeed: 0, toolsSeed: 0)
        let fn = Scripting.Functions.makeCalculateRouteUnit(host: host)
        var engine = Scripting.Engine.reset()
        // Push `currentDestinationEncoded = 0` argument. Not used for
        // this path (route[0] is already 1 = NE so no fresh pathfind),
        // but peek(1) must be readable.
        // Push the same targetMove tile encoding that makeHost set on
        // the unit. `CalculateRoute` rejects IT_NONE at its first gate
        // (`src/script/unit.c:1306` port) so we need a live tile
        // encoding. Tile (11, 9) is the NE neighbour of our SOLDIER
        // at (10, 10).
        let encoded = Scripting.EncodedIndex.tile(packed: 9 &* 64 + 11).raw
        engine.stackPointer = 14
        engine.stack[14] = encoded
        _ = fn(&engine)
        _ = source // unused; kept so the RNG isn't optimised away

        let post = host.units[0]
        // movingSpeed should reflect the CONCRETE_SLAB row for foot
        // (speedPercent=255 passed to Units.setSpeed; movingSpeed is
        // the percent after byScenario downscale — for a non-byScenario
        // unit `255 * 192 / 256 = 191`).
        #expect(post.movingSpeed != 0,
                "foot unit stepping onto structure tile must get non-zero movingSpeed via CONCRETE_SLAB remap")
    }

    @Test("LST_ENTIRELY_ROCK (letUnitWobble=true) sets isWobbling")
    func rockSetsIsWobbling() throws {
        let host = Self.makeHost(nextLandscape: .entirelyRock)
        // Pre-clear so the set is observable.
        var pre = host.units[0]; pre.isWobbling = false; host.units[0] = pre

        let fn = Scripting.Functions.makeCalculateRouteUnit(host: host)
        var engine = Scripting.Engine.reset()
        // Push the same targetMove tile encoding that makeHost set on
        // the unit. `CalculateRoute` rejects IT_NONE at its first gate
        // (`src/script/unit.c:1306` port) so we need a live tile
        // encoding. Tile (11, 9) is the NE neighbour of our SOLDIER
        // at (10, 10).
        let encoded = Scripting.EncodedIndex.tile(packed: 9 &* 64 + 11).raw
        engine.stackPointer = 14
        engine.stack[14] = encoded
        _ = fn(&engine)

        #expect(host.units[0].isWobbling == true,
                "letUnitWobble=true landscape must set isWobbling")
    }

    @Test("LST_NORMAL_SAND (letUnitWobble=false) clears pre-set isWobbling (enhanced path)")
    func sandClearsIsWobbling() throws {
        // Pre-set isWobbling=true (already done by makeHost). After
        // CalculateRoute with a sand next-tile, the enhanced OpenDUNE
        // path at `src/unit.c:1097..1098` must overwrite isWobbling
        // with `letUnitWobble=false`. The non-enhanced vanilla path
        // would leave isWobbling=true — which is what Swift's prior
        // port did, causing the RNG-stream tick-581 drift.
        let host = Self.makeHost(nextLandscape: .normalSand)
        #expect(host.units[0].isWobbling == true, "precondition")

        let fn = Scripting.Functions.makeCalculateRouteUnit(host: host)
        var engine = Scripting.Engine.reset()
        // Push the same targetMove tile encoding that makeHost set on
        // the unit. `CalculateRoute` rejects IT_NONE at its first gate
        // (`src/script/unit.c:1306` port) so we need a live tile
        // encoding. Tile (11, 9) is the NE neighbour of our SOLDIER
        // at (10, 10).
        let encoded = Scripting.EncodedIndex.tile(packed: 9 &* 64 + 11).raw
        engine.stackPointer = 14
        engine.stack[14] = encoded
        _ = fn(&engine)

        #expect(host.units[0].isWobbling == false,
                "enhanced path must clear isWobbling on a non-wobble landscape")
    }

    @Test("LST_STRUCTURE remap also clears isWobbling (structure → slab, neither wobbles)")
    func structureRemapClearsIsWobbling() throws {
        let host = Self.makeHost(nextLandscape: .structure)
        #expect(host.units[0].isWobbling == true, "precondition")

        let fn = Scripting.Functions.makeCalculateRouteUnit(host: host)
        var engine = Scripting.Engine.reset()
        // Push the same targetMove tile encoding that makeHost set on
        // the unit. `CalculateRoute` rejects IT_NONE at its first gate
        // (`src/script/unit.c:1306` port) so we need a live tile
        // encoding. Tile (11, 9) is the NE neighbour of our SOLDIER
        // at (10, 10).
        let encoded = Scripting.EncodedIndex.tile(packed: 9 &* 64 + 11).raw
        engine.stackPointer = 14
        engine.stack[14] = encoded
        _ = fn(&engine)

        #expect(host.units[0].isWobbling == false,
                "LST_STRUCTURE remaps to CONCRETE_SLAB; both have letUnitWobble=false")
    }
}
