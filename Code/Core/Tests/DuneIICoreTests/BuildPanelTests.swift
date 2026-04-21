import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Build panel — bitmask → type list + controller state transitions")
struct BuildPanelTests {

    // MARK: StructureInfo.buildableTypes

    @Test("empty bitmask → empty array")
    func buildableTypesEmpty() {
        #expect(Simulation.StructureInfo.buildableTypes(from: 0) == [])
    }

    @Test("single bit WINDTRAP (type 9) → [9]")
    func buildableTypesSingle() {
        #expect(Simulation.StructureInfo.buildableTypes(from: (1 << 9)) == [9])
    }

    @Test("SLAB_1x1 + WINDTRAP + REFINERY → [0, 9, 12] ascending type-ID order")
    func buildableTypesOrdered() {
        let mask: UInt32 = (1 << 0) | (1 << 9) | (1 << 12)
        #expect(Simulation.StructureInfo.buildableTypes(from: mask) == [0, 9, 12])
    }

    @Test("full bitmask → all 19 structure type IDs")
    func buildableTypesAll() {
        let mask: UInt32 = 0x0007_FFFF  // bits 0..18
        let all: [UInt8] = Array(0...18)
        #expect(Simulation.StructureInfo.buildableTypes(from: mask) == all)
    }

    @Test("ignores bits 19..31 (only type IDs 0..18 are valid)")
    func buildableTypesIgnoresHighBits() {
        let mask: UInt32 = 0xFFFF_FFFF
        let all: [UInt8] = Array(0...18)
        #expect(Simulation.StructureInfo.buildableTypes(from: mask) == all)
    }

    // MARK: BuildPanelController

    @Test("controller starts empty")
    func controllerInitial() {
        let controller = BuildPanelController()
        #expect(controller.selectedYardIndex == nil)
        #expect(controller.placementType == nil)
        #expect(controller.availableTypes == [])
    }

    @Test("refreshAvailableTypes writes availableTypes")
    func controllerRefreshAvailable() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 0])
        #expect(controller.availableTypes == [9, 0])
    }

    @Test("sidebar click on out-of-range slot is a no-op; state unchanged")
    func controllerSidebarOutOfRange() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 0])
        let action = controller.handle(click: .sidebarSlot(index: 99))
        #expect(action == .none)
        #expect(controller.placementType == nil)
    }

    @Test("map click with no placement is a no-op")
    func controllerMapNoPlacement() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        let action = controller.handle(click: .mapTile(x: 5, y: 7))
        #expect(action == .none)
    }

    @Test("outside click is a no-op in all yard states; placement-mode survives outside click")
    func controllerOutsideNoOp() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        // nil state — outside click is a no-op.
        #expect(controller.handle(click: .outside) == .none)
        // Enter placement via READY → queued path, then outside click.
        controller.refreshYardState(.ready, queuedType: 9, countDown: 0, buildTime: 48)
        _ = controller.handle(click: .sidebarSlot(index: 0))
        #expect(controller.placementType == 9)
        #expect(controller.handle(click: .outside) == .none)
        #expect(controller.placementType == 9)  // still placing
    }

    // MARK: Slice 4d-ui — yardState + .enqueue flow

    @Test("IDLE yard + sidebar click → .enqueue(type:)")
    func controllerIdleEnqueues() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 12])
        controller.refreshYardState(.idle, queuedType: nil, countDown: nil, buildTime: nil)
        let action = controller.handle(click: .sidebarSlot(index: 0))
        #expect(action == .enqueue(type: 9))
        // Enqueue does not enter placement mode.
        #expect(controller.placementType == nil)
    }

    @Test("nil yardState (scene not yet populated) + sidebar click → .enqueue")
    func controllerNilStateEnqueues() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        let action = controller.handle(click: .sidebarSlot(index: 0))
        #expect(action == .enqueue(type: 9))
    }

    @Test("BUSY yard + sidebar click → .none")
    func controllerBusyNoOp() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 12])
        controller.refreshYardState(.busy, queuedType: 9, countDown: 6000, buildTime: 48)
        let action = controller.handle(click: .sidebarSlot(index: 0))
        #expect(action == .none)
        let action2 = controller.handle(click: .sidebarSlot(index: 1))
        #expect(action2 == .none)
    }

    @Test("READY yard + click on queued type → .enterPlacement")
    func controllerReadyEntersPlacement() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 12])
        controller.refreshYardState(.ready, queuedType: 9, countDown: 0, buildTime: 48)
        let action = controller.handle(click: .sidebarSlot(index: 0))
        #expect(action == .enterPlacement(type: 9))
        #expect(controller.placementType == 9)
    }

    @Test("READY yard + click on different type → .none (no queue-swap in 4d-ui)")
    func controllerReadyOtherTypeNoOp() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 12])
        controller.refreshYardState(.ready, queuedType: 9, countDown: 0, buildTime: 48)
        let action = controller.handle(click: .sidebarSlot(index: 1))  // type 12
        #expect(action == .none)
        #expect(controller.placementType == nil)
    }

    @Test("READY + .enterPlacement + map click commits as before")
    func controllerReadyThenCommit() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        controller.refreshYardState(.ready, queuedType: 9, countDown: 0, buildTime: 48)
        _ = controller.handle(click: .sidebarSlot(index: 0))
        let action = controller.handle(click: .mapTile(x: 7, y: 7))
        #expect(action == .commitPlacement(type: 9, tileX: 7, tileY: 7))
        #expect(controller.placementType == nil)
    }

    @Test("progress math: countDown == buildTime<<8 → 0.0; countDown == 0 → 1.0; halfway → 0.5")
    func controllerProgressMath() {
        var controller = BuildPanelController()
        // Before refresh: progress is nil.
        #expect(controller.progress == nil)

        // buildTime=48, countDown=48<<8=12288 → progress = 0.0
        controller.refreshYardState(.busy, queuedType: 9, countDown: 12288, buildTime: 48)
        if let p = controller.progress {
            #expect(abs(p - 0.0) < 0.001)
        } else { Issue.record("progress was nil") }

        // countDown=0 → progress = 1.0
        controller.refreshYardState(.ready, queuedType: 9, countDown: 0, buildTime: 48)
        if let p = controller.progress {
            #expect(abs(p - 1.0) < 0.001)
        } else { Issue.record("progress was nil") }

        // countDown = 6144 (half of 12288) → progress = 0.5
        controller.refreshYardState(.busy, queuedType: 9, countDown: 6144, buildTime: 48)
        if let p = controller.progress {
            #expect(abs(p - 0.5) < 0.001)
        } else { Issue.record("progress was nil") }
    }
}
