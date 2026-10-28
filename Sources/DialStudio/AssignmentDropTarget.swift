import SwiftUI
import UlanziKit

struct AssignmentDropTarget: ViewModifier {
    let model: StudioModel
    let control: Control
    var gesture: GestureKind? = nil
    private var key: String { control.rawValue + "/" + (gesture?.rawValue ?? "default") }
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.hoveredDropTarget == key ? Color.accentColor : .clear, lineWidth: 3).allowsHitTesting(false))
            .dropDestination(for: String.self) { items, _ in
                model.assignDrop(items, to: control, gesture: gesture)
            } isTargeted: { targeted in
                if targeted { model.hoveredDropTarget = key }
                else if model.hoveredDropTarget == key { model.hoveredDropTarget = nil }
            }
    }
}

struct AssignmentDragSource: ViewModifier {
    let model: StudioModel
    let control: Control
    var gesture: GestureKind? = nil
    let title: String
    @ViewBuilder func body(content: Content) -> some View {
        if let payload = model.assignmentPayload(control, gesture: gesture) {
            content.draggable(payload) {
                Label(title, systemImage: "arrow.left.arrow.right")
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else { content }
    }
}
