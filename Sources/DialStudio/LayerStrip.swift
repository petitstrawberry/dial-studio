import SwiftUI
import UlanziKit

/// Layers as cards: the small device drawing shows what each layer covers,
/// so a layer can be judged without switching to it.
struct LayerStrip: View {
    let model: StudioModel
    @State private var renaming: UUID?
    @State private var renameProfile: UUID?
    @State private var renameDraft = ""
    @State private var dropTarget: UUID?
    @FocusState private var focus: UUID?
    @Environment(\.colorScheme) private var colorScheme

    private var layers: [StudioPage] { model.profile?.pages ?? [] }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            row
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: focus) { old, new in
            if let id = renaming, old == id, new != id { finishRename() }
        }
        .onChange(of: model.selectedProfile) { _, _ in finishRename() }
        .onChange(of: model.selectedPage) { _, new in
            if let id = renaming, new != id { finishRename() }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                card(layer, index: index)
            }
            addTile
        }
    }

    @ViewBuilder private func card(_ layer: StudioPage, index: Int) -> some View {
        let selected = model.selectedPage == layer.id
        let editing = renaming == layer.id
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title3).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField(L("名前"), text: $renameDraft)
                    .textFieldStyle(.plain).font(.callout.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    .focused($focus, equals: layer.id)
                    .onSubmit { finishRename() }
                    .onExitCommand { cancelRename() }
                    .onAppear {
                        DispatchQueue.main.async {
                            if renaming == layer.id { focus = layer.id }
                        }
                    }
                } else {
                    Text(layer.name).font(.callout.weight(.semibold)).foregroundStyle(colorScheme == .dark ? Color.white : Color.black).lineLimit(1)
                }
                Text(subtitle(layer, index: index))
                    .font(.caption).foregroundStyle((colorScheme == .dark ? Color.white : Color.black).opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isLive(layer.id) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                    .help(L("実機でこのレイヤーを表示中"))
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: 168, height: 56, alignment: .leading)
        .glassCard(RoundedRectangle(cornerRadius: 12), selected: selected)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTarget == layer.id ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if !editing { model.selectPage(layer.id) } }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !editing { beginRename(layer) } })
        .help(helpText(layer, index: index))
        .contextMenu {
            Button(L("名前を変更")) { beginRename(layer) }
            Button(L("複製")) { model.selectPage(layer.id); model.duplicatePage() }
            Divider()
            Button(L("左へ移動")) { model.shiftPage(layer.id, by: -1) }.disabled(index == 0)
            Button(L("右へ移動")) { model.shiftPage(layer.id, by: 1) }.disabled(index == layers.count - 1)
            Divider()
            Button(L("削除")) { model.selectPage(layer.id); model.deletePage() }.disabled(layers.count < 2)
        }
        .modifier(LayerDragSource(layer: layer, enabled: !editing))
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first, payload.hasPrefix("dialstudio/layer/"),
                  let id = UUID(uuidString: String(payload.dropFirst("dialstudio/layer/".count))), id != layer.id else { return false }
            model.movePage(id, before: layer.id)
            return true
        } isTargeted: { active in
            if active { dropTarget = layer.id } else if dropTarget == layer.id { dropTarget = nil }
        }
    }

    private func beginRename(_ layer: StudioPage) {
        finishRename()
        guard let profileID = model.selectedProfile else { return }
        model.selectPage(layer.id)
        renameDraft = layer.name; renameProfile = profileID; renaming = layer.id
    }

    private func finishRename() {
        guard let id = renaming, let profileID = renameProfile else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil; renameProfile = nil; focus = nil
        guard !name.isEmpty else { model.error = L("ページ名を空にはできません。"); return }
        model.renamePage(id, profileID: profileID, name: name)
    }

    private func cancelRename() {
        renaming = nil; renameProfile = nil; focus = nil
    }

    private var addTile: some View {
        Button(action: model.addLayer) {
            VStack(spacing: 3) {
                Image(systemName: "plus").font(.callout.weight(.medium))
                Text(L("ページ")).font(.caption2)
            }
            .frame(width: 88, height: 56)
            .foregroundStyle(Color.primary.opacity(0.75))
            .glassCard(RoundedRectangle(cornerRadius: 12), interactive: false)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).help(L("ページを追加"))
    }

    private func isLive(_ id: UUID) -> Bool {
        model.running && !model.paused && model.state.profileID == model.profile?.id && model.state.layerID == id
    }

    private func subtitle(_ layer: StudioPage, index: Int) -> String {
        var parts: [String] = []
        if index == 0 { parts.append(L("基本")) }
        parts.append(LF("%d レイヤー", layer.layers.count))
        return parts.joined(separator: " · ")
    }

    private func helpText(_ layer: StudioPage, index: Int) -> String {
        var lines = [layer.name]
        if index == 0 { lines.append(L("最初に使用するページです。未設定の入力は実行されません。")) }
        let controls = Set(layer.layers.flatMap(\.bindings).filter(\.enabled).map(\.control))
        if !controls.isEmpty { lines.append(L("設定済み: ") + controls.map(\.title).sorted().joined(separator: "、")) }
        lines.append(L("ダブルクリックで名前を変更"))
        return lines.joined(separator: "\n")
    }
}

private struct LayerDragSource: ViewModifier {
    let layer: StudioPage
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.draggable("dialstudio/layer/\(layer.id.uuidString)") {
                Text(layer.name).font(.callout).padding(6).glassSurface(Capsule())
            }
        } else { content }
    }
}
