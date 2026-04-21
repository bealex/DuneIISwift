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

    @Test("sidebar click on valid slot enters placement mode")
    func controllerSidebarEntersPlacement() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 0, 12])
        let action = controller.handle(click: .sidebarSlot(index: 0))
        #expect(action == .enterPlacement(type: 9))
        #expect(controller.placementType == 9)
    }

    @Test("sidebar click on out-of-range slot is a no-op; state unchanged")
    func controllerSidebarOutOfRange() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 0])
        let action = controller.handle(click: .sidebarSlot(index: 99))
        #expect(action == .none)
        #expect(controller.placementType == nil)
    }

    @Test("map click while placing commits and exits placement mode")
    func controllerMapCommitsPlacement() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        _ = controller.handle(click: .sidebarSlot(index: 0))
        let action = controller.handle(click: .mapTile(x: 5, y: 7))
        #expect(action == .commitPlacement(type: 9, tileX: 5, tileY: 7))
        #expect(controller.placementType == nil)
    }

    @Test("map click with no placement is a no-op")
    func controllerMapNoPlacement() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        let action = controller.handle(click: .mapTile(x: 5, y: 7))
        #expect(action == .none)
    }

    @Test("sidebar re-pick while placing swaps the type without committing")
    func controllerRepick() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9, 12])
        _ = controller.handle(click: .sidebarSlot(index: 0))
        let action = controller.handle(click: .sidebarSlot(index: 1))
        #expect(action == .enterPlacement(type: 12))
        #expect(controller.placementType == 12)
    }

    @Test("outside click is a no-op in any state")
    func controllerOutsideNoOp() {
        var controller = BuildPanelController()
        controller.refreshAvailableTypes([9])
        #expect(controller.handle(click: .outside) == .none)
        _ = controller.handle(click: .sidebarSlot(index: 0))
        #expect(controller.handle(click: .outside) == .none)
        #expect(controller.placementType == 9)  // still placing
    }
}
