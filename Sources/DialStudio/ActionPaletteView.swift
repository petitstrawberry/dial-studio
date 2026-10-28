import SwiftUI
import UlanziKit

/// Action grid in a floating glass shelf. Drop a card onto the device drawing.
struct ActionPaletteView: View {
    let model: StudioModel

    private var groups: [(name: String, items: [ActionTemplate])] {
        ActionTemplate.groups.compactMap { name in
            let items = ActionTemplate.all.filter { $0.group == name }
            return items.isEmpty ? nil : (name, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("アクション")).font(.headline)
                Text(L("実機図へドラッグ")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if groups.isEmpty {
                Text(L("該当するアクションがありません")).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.name) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 6)], spacing: 6) {
                                    ForEach(group.items) { card($0) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 2)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func card(_ template: ActionTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: template.symbol)
                .font(.system(size: 12)).frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
            Text(template.title).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .draggable(template.payload) {
            HStack(spacing: 6) {
                Image(systemName: template.symbol).foregroundStyle(Color.accentColor)
                Text(template.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .help(LF("%@ · %@\nドラッグで割り当て／ダブルクリックで選択中の入力へ", template.group, template.title))
        .contextMenu { Button(L("選択中の入力に追加")) { assign(template) } }
        .onTapGesture(count: 2) { assign(template) }
    }

    private func assign(_ template: ActionTemplate) {
        _ = model.assignDrop([template.payload], to: model.selectedControl, gesture: model.selectedControl == .dial ? .clockwise : nil)
    }
}
