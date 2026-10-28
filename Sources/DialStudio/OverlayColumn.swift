import SwiftUI
import UlanziKit

/// Layers are ordered from low to high priority within the selected page.
struct OverlayColumn: View {
    let model: StudioModel
    @State private var renameID: UUID?
    @State private var renameDraft = ""
    @State private var dropTarget: UUID?

    private var layers: [StudioLayer] { model.page?.layers ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("レイヤー")).font(.headline)
                Spacer()
                Button(action: model.addOverlay) { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help(L("レイヤーを追加"))
            }
            Text(L("上のレイヤーが優先"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(layers.enumerated()).reversed(), id: \.element.id) { index, layer in
                        row(layer, index: index)
                    }
                }
            }
            .scrollIndicators(.automatic)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .alert(L("レイヤー名を変更"), isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField(L("名前"), text: $renameDraft)
            Button(L("キャンセル"), role: .cancel) { renameID = nil }
            Button(L("保存")) {
                let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renameID, let profile = model.selectedProfile, !name.isEmpty { model.renameLayer(id, profileID: profile, name: name) }
                renameID = nil
            }
        }
    }

    private func row(_ layer: StudioLayer, index: Int) -> some View {
        Button { model.selectLayer(layer.id) } label: {
            HStack(spacing: 8) {
                DeviceThumbnail(layer: layer, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(LF("%d 入力", Set(layer.bindings.filter(\.enabled).map(\.control)).count))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.previewOverlayIDs.contains(layer.id) || (model.state.profileID == model.selectedProfile && model.state.activeOverlayIDs?.contains(layer.id) == true && model.running) {
                    Circle().fill(model.previewOverlayIDs.contains(layer.id) ? Color.blue : Color.green).frame(width: 6, height: 6)
                        .help(L("有効なレイヤー"))
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedLayer == layer.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.selectedLayer == layer.id ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(dropTarget == layer.id ? Color.accentColor : .clear, lineWidth: 2))
        .draggable("dialstudio/overlay/\(layer.id.uuidString)") {
            Text(layer.name).font(.callout).padding(6).glassSurface(Capsule())
        }
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, value.hasPrefix("dialstudio/overlay/"), let id = UUID(uuidString: String(value.dropFirst("dialstudio/overlay/".count))), id != layer.id,
                  layers.contains(where: { $0.id == id }) else { return false }
            model.moveLayer(id, before: layer.id); return true
        } isTargeted: { active in
            if active { dropTarget = layer.id } else if dropTarget == layer.id { dropTarget = nil }
        }
        .contextMenu {
            Button(L("名前を変更")) { renameDraft = layer.name; renameID = layer.id }
            Button(L("複製")) { model.selectLayer(layer.id); model.duplicateLayer() }
            Divider()
            Button(L("優先順位を上げる")) { model.shiftLayer(layer.id, by: 1) }.disabled(index == layers.count - 1)
            Button(L("優先順位を下げる")) { model.shiftLayer(layer.id, by: -1) }.disabled(index == 0)
            Divider()
            Button(L("削除")) { model.selectLayer(layer.id); model.deleteLayer() }.disabled(layers.count == 1)
        }
    }
}
