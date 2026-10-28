import XCTest
import UlanziKit
@testable import DialStudio

final class DragEditingTests: XCTestCase {
    private func model() -> StudioModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return StudioModel(url: url, demonstration: true)
    }

    func testDialShortcutsCanUseDifferentKeysForEachDirection() throws {
        let model = model()
        let template = try XCTUnwrap(ActionTemplate.all.first { $0.id == "system.shortcut" })
        XCTAssertTrue(model.assignDrop([template.payload], to: .dial, gesture: .clockwise))
        XCTAssertTrue(model.assignDrop([template.payload], to: .dial, gesture: .counterclockwise))
        let bindings = try XCTUnwrap(model.layer?.bindings)
        let right = try XCTUnwrap(bindings.first { $0.control == .dial && $0.gesture == .clockwise })
        let left = try XCTUnwrap(bindings.first { $0.control == .dial && $0.gesture == .counterclockwise })
        model.updateAction(right.id, stepID: nil) { $0.value = "ctrl+alt+right" }
        model.updateAction(left.id, stepID: nil) { $0.value = "ctrl+alt+left" }
        XCTAssertEqual(model.layer?.bindings.first { $0.id == right.id }?.action.value, "ctrl+alt+right")
        XCTAssertEqual(model.layer?.bindings.first { $0.id == left.id }?.action.value, "ctrl+alt+left")
        try model.configuration.validate()
    }

    func testAddButtonBindingStartsWithPressThenUsesAnotherFreeGesture() throws {
        let model = model()
        model.selectedControl = .rightBottom
        model.addBinding()
        XCTAssertEqual(model.binding?.gesture, .press)
        model.addBinding()
        XCTAssertEqual(model.binding?.gesture, .tap)
    }


    func testSwapButtonsMovesAllBindingsAndRejectsInvalidChord() throws {
        let model = model()
        let a = StudioBinding(name: "A", control: .topLeft, gesture: .tap)
        let b = StudioBinding(name: "B", control: .topLeft, gesture: .hold)
        let c = StudioBinding(name: "C", control: .topRight, gesture: .tap)
        model.editLayer { $0.bindings = [a, b, c] }
        let payload = try XCTUnwrap(model.assignmentPayload(.topLeft))
        XCTAssertTrue(model.assignDrop([payload], to: .topRight))
        XCTAssertEqual(model.layer?.bindings.map(\.control), [.topRight, .topRight, .topLeft])
        model.editLayer { $0.bindings[0].held = [.topLeft] }
        let invalid = try XCTUnwrap(model.assignmentPayload(.topRight))
        let previous = model.configuration
        XCTAssertFalse(model.assignDrop([invalid], to: .topLeft))
        XCTAssertEqual(model.configuration, previous)
    }

    func testSwapDialDirectionsAndMoveActionPreservesWaitPositions() throws {
        let model = model()
        var left = StudioBinding(name: "Left", control: .dial, gesture: .counterclockwise, action: StudioAction(.media, value: "previous"))
        left.steps = [ActionStep(action: StudioAction(.media, value: "next"), delayMilliseconds: 250), ActionStep(action: StudioAction(.media, value: "mute"), delayMilliseconds: 500)]
        let right = StudioBinding(name: "Right", control: .dial, gesture: .clockwise, action: StudioAction(.media, value: "next"))
        model.editLayer { $0.bindings = [left, right] }
        let payload = try XCTUnwrap(model.assignmentPayload(.dial, gesture: .counterclockwise))
        XCTAssertTrue(model.assignDrop([payload], to: .dial, gesture: .clockwise))
        XCTAssertEqual(model.layer?.bindings.map(\.gesture), [.clockwise, .counterclockwise])
        XCTAssertTrue(model.moveAction(left.id, from: 0, to: 2))
        let result = try XCTUnwrap(model.layer?.bindings.first { $0.id == left.id })
        XCTAssertEqual(([result.action] + (result.steps ?? []).map(\.action)).map(\.value), ["next", "mute", "previous"])
        XCTAssertEqual(result.steps?.map(\.delayMilliseconds), [250, 500])
    }

    func testPageAndLayerEditingAreIndependent() throws {
        let model = model()
        let first = StudioPage(name: "First", layers: [StudioLayer(name: "Bottom"), StudioLayer(name: "Top")])
        let second = StudioPage(name: "Second", layers: [StudioLayer(name: "Other")])
        let profile = StudioProfile(pages: [first, second])
        model.configuration = StudioConfiguration(profiles: [profile]); model.selectProfile(profile.id)
        model.renamePage(first.id, profileID: profile.id, name: "Page renamed")
        model.renameLayer(first.layers[0].id, profileID: profile.id, name: "Layer renamed")
        XCTAssertEqual(model.page?.name, "Page renamed")
        XCTAssertEqual(model.layer?.name, "Layer renamed")
        model.shiftLayer(first.layers[0].id, by: 1)
        XCTAssertEqual(model.page?.layers.map(\.name), ["Top", "Layer renamed"])
        model.selectPage(second.id)
        XCTAssertEqual(model.page?.layers.map(\.name), ["Other"])
        model.movePage(second.id, before: first.id)
        XCTAssertEqual(model.profile?.pages.map(\.name), ["Second", "Page renamed"])
        try model.configuration.validate()
    }
    func testPageDuplicationCopiesItsLayersAndRetargetsActions() throws {
        let model = model()
        var bottom = StudioLayer(name: "Bottom")
        let overlay = StudioLayer(name: "Overlay")
        bottom.bindings = [StudioBinding(control: .topLeft, gesture: .press, action: StudioAction(.overlayHold, layer: overlay.id))]
        let page = StudioPage(name: "Page", layers: [bottom, overlay])
        let other = StudioPage(name: "Other")
        let profile = StudioProfile(pages: [page, other])
        model.configuration = StudioConfiguration(profiles: [profile]); model.selectProfile(profile.id)
        model.duplicatePage()
        let copy = try XCTUnwrap(model.page)
        XCTAssertNotEqual(copy.id, page.id); XCTAssertNotEqual(copy.layers[1].id, overlay.id)
        XCTAssertEqual(copy.layers[0].bindings[0].action.targetLayer, copy.layers[1].id)
        try model.configuration.validate()
        model.deletePage()
        XCTAssertEqual(model.profile?.pages.count, 2)
        try model.configuration.validate()
        model.duplicateProfile()
        let duplicated = try XCTUnwrap(model.profile)
        XCTAssertNotEqual(duplicated.pages[0].id, page.id)
        XCTAssertEqual(duplicated.pages[0].layers[0].bindings[0].action.targetLayer, duplicated.pages[0].layers[1].id)
        try model.configuration.validate()
    }
    func testOverlayEditorPreviewUsesSelectedPage() throws {
        let model = model()
        let first = StudioPage(name: "First")
        var bottom = StudioLayer(name: "Bottom")
        let overlay = StudioLayer(name: "Overlay")
        bottom.bindings = [StudioBinding(control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: overlay.id))]
        let second = StudioPage(name: "Second", layers: [bottom, overlay])
        let profile = StudioProfile(pages: [first, second])
        model.configuration = StudioConfiguration(profiles: [profile]); model.selectProfile(profile.id)
        model.selectPage(second.id); model.selectLayer(overlay.id)
        model.simulate(ControlEvent(.leftTop, .down))
        XCTAssertEqual(model.selectedPage, second.id)
        XCTAssertEqual(model.previewOverlayIDs, [overlay.id])
        XCTAssertEqual(model.previewName, "Second + Overlay")
        model.simulate(ControlEvent(.leftTop, .up))
        XCTAssertTrue(model.previewOverlayIDs.isEmpty)
    }
    func testDeleteLayerRemovesAllSequenceReferences() throws {
        let model = model()
        let target = StudioLayer(name: "Target")
        var binding = StudioBinding(control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: target.id))
        binding.steps = [ActionStep(action: StudioAction(.overlayToggle, layer: target.id)), ActionStep(action: StudioAction(.shortcut, value: "space"))]
        let page = StudioPage(layers: [StudioLayer(bindings: [binding]), target])
        let profile = StudioProfile(pages: [page]); model.configuration = StudioConfiguration(profiles: [profile]); model.selectProfile(profile.id)
        model.selectLayer(target.id); model.deleteLayer()
        let result = try XCTUnwrap(model.layer?.bindings.first)
        XCTAssertEqual(result.action.type, .shortcut)
        XCTAssertNil(result.steps)
        try model.configuration.validate()
    }
    func testReorderingLayerKeepsReferencesValid() throws {
        let model = model()
        let top = StudioLayer(name: "Top")
        let binding = StudioBinding(control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: top.id))
        let page = StudioPage(layers: [StudioLayer(bindings: [binding]), top])
        let profile = StudioProfile(pages: [page]); model.configuration = StudioConfiguration(profiles: [profile]); model.selectProfile(profile.id)
        model.moveLayer(top.id, before: page.layers[0].id)
        XCTAssertEqual(model.page?.layers.first?.id, top.id)
        try model.configuration.validate()
    }

    func testTimelineDropAssignsRequestedButtonEvent() throws {
        let model = model()
        model.addOverlay()
        let bottom = try XCTUnwrap(model.page?.layers.first)
        model.selectLayer(bottom.id)
        let template = try XCTUnwrap(ActionTemplate.all.first { $0.id == "overlay.hold" })
        XCTAssertTrue(model.assignDrop([template.payload], to: .topLeft, gesture: .hold))
        let binding = try XCTUnwrap(model.layer?.bindings.first { $0.control == .topLeft && $0.gesture == .hold })
        XCTAssertEqual(binding.action.type, .overlayHold)
        try model.configuration.validate()
    }
    func testTimelineMovesBindingAndRejectsInvalidDestinations() throws {
        let model = model()
        let overlay = StudioLayer(name: "Overlay")
        let continuous = StudioBinding(name: "hold", control: .topLeft, gesture: .press, action: StudioAction(.overlayHold, layer: overlay.id))
        let occupied = StudioBinding(name: "existing", control: .topLeft, gesture: .release, action: StudioAction(.shortcut, value: "space"))
        let movable = StudioBinding(name: "move", control: .topLeft, gesture: .tap, action: StudioAction(.shortcut, value: "a"))
        let page = StudioPage(layers: [StudioLayer(bindings: [continuous, occupied, movable]), overlay])
        let profile = StudioProfile(pages: [page]); model.configuration = StudioConfiguration(profiles: [profile]); model.selectProfile(profile.id)
        model.selectedControl = .topLeft
        XCTAssertFalse(model.moveTimelineBinding(continuous.id, to: .tap))
        XCTAssertFalse(model.moveTimelineBinding(movable.id, to: .release))
        XCTAssertTrue(model.moveTimelineBinding(movable.id, to: .holdRelease))
        XCTAssertEqual(model.layer?.bindings.first(where: { $0.id == movable.id })?.gesture, .holdRelease)
        XCTAssertEqual(model.layer?.bindings.first(where: { $0.id == continuous.id })?.gesture, .press)
        try model.configuration.validate()
    }
}
