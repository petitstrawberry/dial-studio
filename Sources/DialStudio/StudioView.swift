import SwiftUI
import AppKit
import UlanziKit

struct StudioView: View {
    @Bindable var model: StudioModel
    @State private var showConditions = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var actionDropTarget: UUID?
    @State private var actionReorderTarget: String?
    @State private var timelineDropTarget: GestureKind?
    @State private var timelineExpanded: Set<UUID> = []
    @State private var timelineBindingTarget: UUID?

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
                    .navigationSplitViewColumnWidth(210)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                HStack(spacing: 0) {
                    content.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        Divider()
                        detail.frame(minWidth: 290, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        columns = columns == .all ? .detailOnly : .all
                    } label: {
                        Image(systemName: "sidebar.left")
                    }.help(L("サイドバーを表示 / 非表示"))
                }
                ToolbarItem(placement: .automatic) { Spacer() }
                toolbar
                ToolbarItem(placement: .primaryAction) {
                    Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(L("詳細を表示／非表示"))
                }
            }
            .frame(width: geometry.size.width, height: max(0, geometry.size.height - 32), alignment: .top)
            .clipped()
            statusBar
                .frame(height: 32)
        }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showLog) { LogView(model: model) }
        .alert(L("確認してください"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(L("閉じる")) { model.error = nil } } message: { Text(model.error ?? "") }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
        List(selection: Binding(get: { model.selectedProfile }, set: { if let id = $0 { model.selectProfile(id) } })) {
            Section(L("プロファイル")) {
                ForEach(model.configuration.profiles) { profile in
                    HStack(spacing: 6) {
                        ProfileApplicationIcon(bundleID: profile.bundleID, iconData: profile.iconData)
                            .frame(width: 16, height: 16)
                        Text(profile.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.running && model.state.profileID == profile.id {
                            Circle().fill(Color.green).frame(width: 5, height: 5).help(L("実機で選択中"))
                        }
                    }
                    .opacity(profile.enabled ? 1 : 0.45)
                    .tag(profile.id)
                    .contextMenu {
                        Button(L("複製")) { model.selectProfile(profile.id); model.duplicateProfile() }
                        Button(L("上へ移動")) { model.shiftProfile(profile.id, by: -1) }
                            .disabled(model.configuration.profiles.first?.id == profile.id)
                        Button(L("下へ移動")) { model.shiftProfile(profile.id, by: 1) }
                            .disabled(model.configuration.profiles.last?.id == profile.id)
                        Button(L("削除")) { model.selectProfile(profile.id); model.deleteProfile() }
                    }
                }
                .onMove(perform: model.moveProfiles)
            }
        }
        .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button(action: model.addProfile) { Image(systemName: "plus") }.help(L("プロファイルを追加"))
                Button(action: model.deleteProfile) { Image(systemName: "minus") }.disabled(model.profile == nil).help(L("プロファイルを削除"))
                Spacer()
                Menu {
                    Button(L("プロファイルを複製"), action: model.duplicateProfile).disabled(model.profile == nil)
                    Divider()
                    Button(L("設定を読み込む…"), action: model.importConfiguration)
                    Button(L("設定を書き出す…"), action: model.exportConfiguration)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            if model.profile != nil {
                DisclosureGroup(L("プロファイルの条件"), isExpanded: $showConditions) {
                    Form {
                        TextField(L("名前:"), text: profileText(\.name))
                        LabeledContent(L("アイコン:")) {
                            Menu {
                                Button(L("画像を選択…"), action: model.chooseProfileIcon)
                                Button(L("アプリのアイコンに戻す")) { model.editProfile { $0.iconData = nil } }
                                    .disabled(model.profile?.iconData == nil)
                            } label: {
                                HStack {
                                    ProfileApplicationIcon(bundleID: model.profile?.bundleID ?? "", iconData: model.profile?.iconData)
                                        .frame(width: 18, height: 18)
                                    Text(model.profile?.iconData == nil ? L("自動") : L("選択した画像"))
                                }
                            }
                        }
                        HStack {
                            TextField(L("アプリ:"), text: profileText(\.bundleID), prompt: Text(L("すべてのアプリ")))
                            Menu(L("選択")) {
                                Button(L("すべてのアプリ")) { model.setProfileApplication("") }
                                Button(L("アプリを選択…"), action: model.chooseProfileApplication)
                                Divider()
                                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                                    Button { model.setProfileApplication(app.bundleIdentifier!) } label: {
                                        Label {
                                            Text(app.localizedName ?? app.bundleIdentifier!)
                                        } icon: {
                                            ProfileApplicationIcon(bundleID: app.bundleIdentifier!, iconData: nil)
                                        }
                                    }
                                }
                            }.fixedSize()
                        }
                        if model.profile?.bundleID == "com.google.Chrome" || model.profile?.host.isEmpty == false {
                            TextField(L("サイト:"), text: profileText(\.host), prompt: Text(L("例: youtube.com")))
                        }
                        TextField(L("タイトル:"), text: Binding(get: { model.profile?.titleContains ?? "" }, set: { value in model.editProfile { $0.titleContains = value.isEmpty ? nil : value } }), prompt: Text(L("タイトルに含まれる文字（任意）")))
                        Toggle(L("このプロファイルを有効にする"), isOn: Binding(get: { model.profile?.enabled ?? false }, set: { value in model.editProfile { $0.enabled = value } }))
                    }.textFieldStyle(.roundedBorder).padding(.top, 6).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                LayerStrip(model: model)
                HStack(spacing: 0) {
                    OverlayColumn(model: model)
                    Divider()
                    DeviceView(model: model)
                }
                Divider()
                ActionPaletteView(model: model)
                    .frame(minHeight: 100, maxHeight: .infinity)
            } else {
                Spacer()
                Text(L("プロファイルを選択してください")).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        let bindings = model.bindings(for: model.selectedControl)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.selectedControl.title).font(.headline)
                if model.selectedControl == .dial { Text(L("通常回転と押し回しは別々")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.profile != nil {
                    Button(action: model.addBinding) { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help(L("条件違いの割り当てを追加"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            if let current = model.layer {
                Text(LF("編集中のレイヤー: %@", current.name))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
            }
            if model.selectedControl != .dial {
                buttonTimeline(bindings)
            } else if bindings.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line").font(.title3).foregroundStyle(.tertiary)
                    Text(model.layerIsAboveBottom ? L("未設定（下に透過）") : L("未設定")).font(.callout.weight(.medium))
                    Text(L("アクションを、実機図のこの入力へドラッグしてください。")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
                Spacer()
            } else {
                Form {
                    ForEach(bindings) { binding in
                        Section {
                            bindingEditor(binding)
                        } header: {
                            HStack(spacing: 6) {
                                Text(heading(binding)).font(.subheadline.weight(.semibold))
                                Spacer()
                                Button { model.deleteBinding(binding.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("この割り当てを削除"))
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
        }
    }

    private func buttonTimeline(_ bindings: [StudioBinding]) -> some View {
        let events: [GestureKind] = [.press, .hold, .release, .tap, .holdRelease]
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element) { index, gesture in
                    timelineEvent(gesture, bindings: bindings.filter { $0.gesture == gesture }, first: index == 0, last: index == events.count - 1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
        }
    }

    private func timelineEvent(_ gesture: GestureKind, bindings: [StudioBinding], first: Bool, last: Bool) -> some View {
        let conditional = gesture == .hold || gesture == .tap || gesture == .holdRelease
        let branch = gesture == .tap || gesture == .holdRelease
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(gesture.title).font(.callout.weight(.semibold))
                Spacer(minLength: 2)
                if gesture == .press { Text("0 ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                else if gesture == .hold { Text("≥ \(model.configuration.holdMilliseconds) ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                if conditional { Text(L("条件付き")).font(.caption2).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard bindings.isEmpty || items.first?.hasPrefix("dialstudio/timeline/") == true else { return false }
                return timelineDrop(items, gesture: gesture)
            }
            ForEach(bindings) { binding in
                DisclosureGroup(isExpanded: Binding(
                    get: { timelineExpanded.contains(binding.id) },
                    set: { if $0 { timelineExpanded.insert(binding.id) } else { timelineExpanded.remove(binding.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 8) {
                        bindingEditor(binding, showGesture: false)
                        HStack {
                            Spacer()
                            Button(role: .destructive) { model.deleteBinding(binding.id) } label: { Label(L("削除"), systemImage: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }.padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        if let profile = model.selectedProfile, let layer = model.selectedLayer {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .draggable("dialstudio/timeline/\(profile.uuidString)/\(layer.uuidString)/\(binding.id.uuidString)") {
                                    Text(binding.name).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .help(L("ドラッグしてタイミングを移動"))
                        }
                        Image(systemName: symbol(for: binding.action.type)).foregroundStyle(.secondary)
                        Text(binding.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if !binding.enabled { Text(L("無効")).font(.caption2).foregroundStyle(.secondary) }
                        if let count = binding.steps?.count, count > 0 { Text("+\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    }.font(.callout)
                }
                .padding(9)
                .background(timelineBindingTarget == binding.id ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .dropDestination(for: String.self) { items, _ in
                    if items.first?.hasPrefix("dialstudio/timeline/") == true { return timelineDrop(items, gesture: gesture) }
                    return model.appendAction(items, binding: binding)
                } isTargeted: { active in
                    if active { timelineBindingTarget = binding.id } else if timelineBindingTarget == binding.id { timelineBindingTarget = nil }
                }
            }
            if bindings.isEmpty {
                Label(L("アクションをドロップ"), systemImage: "plus")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(timelineDropTarget == gesture ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .dropDestination(for: String.self) { items, _ in timelineDrop(items, gesture: gesture) } isTargeted: { active in
                        if active { timelineDropTarget = gesture } else if timelineDropTarget == gesture { timelineDropTarget = nil }
                    }
            }
        }
        .padding(.leading, branch ? 42 : 30)
        .padding(.bottom, last ? 0 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            GeometryReader { geometry in
                let x: CGFloat = 8
                Path { path in
                    path.move(to: CGPoint(x: x, y: first ? 9 : 0))
                    path.addLine(to: CGPoint(x: x, y: last ? 9 : geometry.size.height))
                    if branch { path.move(to: CGPoint(x: x, y: 9)); path.addLine(to: CGPoint(x: 22, y: 9)) }
                }.stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                Circle().fill(conditional ? Color(nsColor: .windowBackgroundColor) : Color.accentColor)
                    .overlay(Circle().strokeBorder(conditional ? Color.secondary.opacity(0.55) : Color.accentColor, lineWidth: 1.5))
                    .frame(width: 10, height: 10).position(x: branch ? 22 : x, y: 9)
            }.allowsHitTesting(false)
        }
    }

    private func timelineDrop(_ items: [String], gesture: GestureKind) -> Bool {
        guard items.count == 1, let first = items.first else { return false }
        if first.hasPrefix("dialstudio/timeline/") {
            let parts = first.split(separator: "/")
            guard parts.count == 5, UUID(uuidString: String(parts[2])) == model.selectedProfile,
                  UUID(uuidString: String(parts[3])) == model.selectedLayer,
                  let id = UUID(uuidString: String(parts[4])) else { return false }
            return model.moveTimelineBinding(id, to: gesture)
        }
        if ActionTemplate.from(payload: first)?.action.type == .overlayHold, ![.press, .hold].contains(gesture) {
            model.error = L("継続アクションは「押した時」か「長押し成立時」に追加してください")
            return false
        }
        return model.assignDrop(items, to: model.selectedControl, gesture: gesture)
    }

    @ViewBuilder private func bindingEditor(_ binding: StudioBinding, showGesture: Bool = true) -> some View {
        TextField(L("名前"), text: text(\.name, in: binding))
        Toggle(L("有効"), isOn: value(\.enabled, in: binding))
        if showGesture {
            Picker(L("操作"), selection: value(\.gesture, in: binding)) {
                ForEach(GestureKind.allCases.filter {
                    let compatible = (binding.control == .dial) == $0.isRotation
                    let hasContinuous = binding.action.type == .overlayHold || (binding.steps ?? []).contains { $0.action.type == .overlayHold }
                    return compatible && (!hasContinuous || [.press, .hold].contains($0))
                }) { Text($0.title).tag($0) }
            }
        }
        if !binding.held.isEmpty {
            HStack {
                Text(LF("同時押し: %@", binding.held.map(\.title).sorted().joined(separator: " + "))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("解除")) { model.updateBinding(binding.id) { $0.held.removeAll() } }.buttonStyle(.borderless)
            }
        }
        HStack(spacing: 4) {
            Text(L("修飾キー")).font(.callout)
            Spacer()
            ForEach(KeyModifier.allCases) { modifier in
                Toggle(modifier.title, isOn: Binding(
                    get: { binding.modifiers.contains(modifier) },
                    set: { checked in model.updateBinding(binding.id) { if checked { $0.modifiers.insert(modifier) } else { $0.modifiers.remove(modifier) } } }
                )).toggleStyle(.button).controlSize(.small)
            }
        }
        actionSection(binding)
    }

    private func actionSection(_ binding: StudioBinding) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if binding.action.type != .none {
                actionRow(binding, action: binding.action, stepID: nil, index: 0, count: 1 + (binding.steps?.count ?? 0))
            }
            ForEach(Array((binding.steps ?? []).enumerated()), id: \.element.id) { index, step in
                Divider()
                HStack {
                    Text(L("この位置の前の待ち時間")).font(.caption).foregroundStyle(.secondary)
                    TextField("0", value: Binding(get: { step.delayMilliseconds }, set: { milliseconds in
                        model.updateBinding(binding.id) { value in
                            if let i = value.steps?.firstIndex(where: { $0.id == step.id }) { value.steps![i].delayMilliseconds = milliseconds }
                        }
                    }), format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    Text(L("ミリ秒")).font(.caption).foregroundStyle(.secondary)
                }
                actionRow(binding, action: step.action, stepID: step.id, index: index + 1, count: 1 + (binding.steps?.count ?? 0))
            }
            Text(binding.action.type == .none ? L("ここへアクションをドラッグ") : L("ここへドラッグしてアクションを追加"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(actionDropTarget == binding.id ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .dropDestination(for: String.self) { items, _ in model.appendAction(items, binding: binding) } isTargeted: { active in
                    if active { actionDropTarget = binding.id } else if actionDropTarget == binding.id { actionDropTarget = nil }
                }
            if binding.steps?.isEmpty == false {
                Text(L("上から順に実行。エラーやアプリの切り替えで残りを中止します。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.top, 2)
    }

    private func actionRow(_ binding: StudioBinding, action: StudioAction, stepID: UUID?, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if count > 1 {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .padding(4).contentShape(Rectangle())
                        .draggable("dialstudio/action/\(binding.id.uuidString)/\(index)") {
                            Label(actionTitle(action), systemImage: symbol(for: action.type))
                                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .help(L("ドラッグして実行順を変更"))
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: symbol(for: action.type)).frame(width: 16).foregroundStyle(.secondary)
                Text(actionTitle(action)).font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if count > 1 {
                    Button { model.moveAction(binding.id, stepID: stepID, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help(L("上へ移動"))
                    Button { model.moveAction(binding.id, stepID: stepID, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1).help(L("下へ移動"))
                }
                Button(L("解除")) { model.removeAction(binding.id, stepID: stepID) }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            actionParameters(binding, action: action, stepID: stepID)
        }
        .padding(4)
        .background(actionReorderTarget == "\(binding.id)/\(index)" ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { items, _ in
            guard items.count == 1 else { return false }
            let parts = items[0].split(separator: "/")
            guard parts.count == 4, parts[0] == "dialstudio", parts[1] == "action",
                  UUID(uuidString: String(parts[2])) == binding.id, let source = Int(parts[3]) else { return false }
            return model.moveAction(binding.id, from: source, to: index)
        } isTargeted: { active in
            let key = "\(binding.id)/\(index)"
            if active { actionReorderTarget = key } else if actionReorderTarget == key { actionReorderTarget = nil }
        }
    }

    private struct ActionTarget: Identifiable { let id: UUID; let name: String }
    private func actionTargets(_ action: StudioAction) -> [ActionTarget] {
        if [.overlayHold, .overlayToggle].contains(action.type) {
            let layers = model.page?.layers ?? []
            let targets = layers.filter { $0.id == action.targetLayer || $0.id != layers.first?.id }
            return targets.map { ActionTarget(id: $0.id, name: $0.name) }
        }
        return (model.profile?.pages ?? []).map { ActionTarget(id: $0.id, name: $0.name) }
    }

    @ViewBuilder private func actionParameters(_ binding: StudioBinding, action: StudioAction, stepID: UUID?) -> some View {
        if [.switchLayer, .overlayHold, .overlayToggle].contains(action.type) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 5)], spacing: 5) {
                ForEach(actionTargets(action)) { layer in
                    let on = action.targetLayer == layer.id
                    Button { model.updateAction(binding.id, stepID: stepID) { $0.targetLayer = layer.id } } label: {
                        Text(layer.name).font(.caption).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }.buttonStyle(.plain)
                }
            }
            Text([.overlayHold, .overlayToggle].contains(action.type) ? L("レイヤーの未設定は下に透過します。") : L("この入力で指定したページへ移動します。")).font(.caption2).foregroundStyle(.secondary)
            if binding.control == .knob && action.type == .overlayHold {
                Text(L("ノブの押し続けは検出できません。押しながらの回転はノブ回転の「押し回し」に割り当ててください。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if action.type == .previousPage || action.type == .cycleLayer {
            Text(L("ページの並び順に移動し、端では反対側に戻ります。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else if action.type == .switchProfile {
            Picker(L("切り替え先"), selection: Binding(get: { action.targetProfile }, set: { id in model.updateAction(binding.id, stepID: stepID) { $0.targetProfile = id } })) {
                ForEach(model.configuration.profiles) { profile in
                    Text(profile.name + (profile.enabled ? "" : L("（無効）"))).tag(Optional(profile.id)).disabled(!profile.enabled)
                }
            }
            Text(L("手動で選んだプロファイルは、自動切り替えに戻すまで維持されます。無効なプロファイルは選べません。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else if action.type == .cycleProfile || action.type == .automaticProfile {
            Text(action.type == .cycleProfile ? L("有効なプロファイルを順番に手動選択します。") : L("前面アプリに応じた自動切り替えに戻します。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else if action.type == .midi {
            if ["jog", "vpot"].contains(action.value) { amountField(binding, action: action, stepID: stepID) }
            if action.value == "vpot" || action.value == "fader" {
                Picker(action.value == "vpot" ? "V-Pot" : L("フェーダー"), selection: Binding(get: { action.mcuIndex ?? 0 }, set: { index in model.updateAction(binding.id, stepID: stepID) { $0.mcuIndex = index } })) {
                    ForEach(0..<(action.value == "vpot" ? 8 : 9), id: \.self) { index in
                        Text(index == 8 ? L("マスター") : "\(index + 1)").tag(index)
                    }
                }
                if action.value == "fader" {
                    amountField(binding, action: action, stepID: stepID)
                    Text(L("位置は0〜16383の絶対値です。タッチ・移動・リリースを送ります。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if ["control", "controlDown", "controlUp"].contains(action.value) {
                Picker(L("Mackie ボタン"), selection: Binding(get: { action.mcuIndex ?? 0x5e }, set: { index in model.updateAction(binding.id, stepID: stepID) { $0.mcuIndex = index } })) {
                    ForEach(MCU.controls, id: \.id) { control in Text(control.name).tag(control.id) }
                }
                Text(action.value == "control" ? L("押下と解放を連続で送ります。") : L("押下・解放を別々に送ります。両方を対応する操作に割り当ててください。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if action.value == "recordStop" {
                Text(L("Logic の録音状態を確認し、録音中なら停止、それ以外なら録音します。アクセシビリティ許可が必要です。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if action.value == "recordBegin" || action.value == "recordEnd" {
                Text(action.value == "recordBegin" ? L("録音中でなければ録音を開始します。") : L("録音中だけ録音を終了し、再生を続けます。Logicの「録音/録音を切り替え」に割り当てたキーを指定してください。"))
                    .font(.caption2).foregroundStyle(.secondary)
                if action.value == "recordEnd" {
                    ShortcutEditor(value: Binding(get: { action.keyCommand ?? "keypadmultiply" }, set: { value in model.updateAction(binding.id, stepID: stepID) { $0.keyCommand = value } }))
                }
            }
            Text(L("DAWにMackie Controlを追加し、入出力を Dial Studio MCU に設定してください。機能はDAW側の割り当てに従います。")).font(.caption2).foregroundStyle(.secondary)
        } else if action.type == .media {
            if action.value == "volume" || action.value == "seek" { amountField(binding, action: action, stepID: stepID) }
            Text(action.value == "seek" ? L("macOSで再生中のメディアを秒数で移動します。対応するアプリで使用できます。") : (action.value == "volume" ? L("現在の音声出力の音量を変更します。負の値で音量を下げます。") : (action.value == "mute" ? L("現在の音声出力のミュートを切り替えます。") : L("macOSのメディアキーを送ります。操作対象はmacOSが選びます。"))))
                .font(.caption2).foregroundStyle(.secondary)
        } else if [.shell, .appleScript, .browserScript].contains(action.type) {
            TextEditor(text: actionText(binding, action: action, stepID: stepID)).font(.system(size: 11, design: .monospaced))
                .frame(height: 130).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            amountField(binding, action: action, stepID: stepID)
            Text(action.type == .browserScript ? L("ctx / amount / return が使えます。") : L("DIAL_CONTEXT_JSON と DIAL_AMOUNT を渡します。")).font(.caption2).foregroundStyle(.secondary)
        } else if action.type == .shortcut {
            ShortcutEditor(value: actionText(binding, action: action, stepID: stepID))
        } else if action.type == .scroll {
            amountField(binding, action: action, stepID: stepID)
        }
    }

    private func amountField(_ binding: StudioBinding, action: StudioAction, stepID: UUID?) -> some View {
        TextField(L("操作量"), value: Binding(get: { action.amount }, set: { newValue in model.updateAction(binding.id, stepID: stepID) { $0.amount = newValue } }), format: .number)
            .textFieldStyle(.roundedBorder).controlSize(.small)
    }

    private func heading(_ binding: StudioBinding) -> String {
        var suffix: [String] = []
        if !binding.held.isEmpty { suffix.append(binding.held.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: "+")) }
        if !binding.modifiers.isEmpty { suffix.append(binding.modifiers.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined()) }
        return suffix.isEmpty ? binding.gesture.title : binding.gesture.title + " · " + suffix.joined(separator: " ")
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(L("右へ回す")) { model.simulate(ControlEvent(.dial, .rotate, delta: 1)) }
                Button(L("左へ回す")) { model.simulate(ControlEvent(.dial, .rotate, delta: -1)) }
                Button(L("押しながら右へ回す")) { model.simulate(ControlEvent(.dial, .rotate, delta: 1, pressedRotation: true)) }
                Button(L("押しながら左へ回す")) { model.simulate(ControlEvent(.dial, .rotate, delta: -1, pressedRotation: true)) }
                Divider()
                Menu(L("ボタン")) {
                    ForEach(Control.buttons) { control in
                        Menu(control.title) {
                            Button(L("短押し")) { model.tap(control) }
                            Button(L("長押し")) { model.tap(control, long: true) }
                            Button(model.previewHeld.contains(control) ? L("離す") : L("押したまま")) { model.simulate(ControlEvent(control, model.previewHeld.contains(control) ? .up : .down)) }
                        }
                    }
                }
                Menu(L("修飾キー")) {
                    ForEach(KeyModifier.allCases) { modifier in
                        Toggle(modifier.title, isOn: Binding(get: { model.previewModifiers.contains(modifier) }, set: { if $0 { model.previewModifiers.insert(modifier) } else { model.previewModifiers.remove(modifier) } }))
                    }
                }
                Divider()
                Button(L("プレビューをリセット"), action: model.resetPreview)
            } label: { Label(L("テスト"), systemImage: "play.circle") }
                .help(L("割り当てをテストします"))
            Button { model.showLog = true } label: { Label(L("ログ"), systemImage: "text.alignleft") }
                .help(L("実行ログを表示"))
            Button { model.showSettings = true } label: { Label(L("設定"), systemImage: "gearshape") }
                .help(L("接続とサービス"))
            Button(action: model.save) { Label(model.dirty ? L("保存") : L("保存済み"), systemImage: "square.and.arrow.down") }
                .help(L("設定を保存してサービスに反映"))
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
        Divider()
        HStack(spacing: 8) {
            Circle().fill(model.state.connected == true ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(model.demonstration ? L("プレビュー（サービス停止中）") : (model.running ? (model.state.connected == true ? L("D100H 接続中") : (model.state.text ?? L("接続待ち"))) : L("サービス停止中")))
            if let profile = model.state.profileName { Text("\(profile) — \(model.state.layerName ?? "")\(model.state.profilePinned == true ? L("（手動）") : "")").foregroundStyle(.secondary) }
            if !model.previewName.isEmpty { Text(LF("テスト: %@", model.previewName)).foregroundStyle(.secondary) }
            Spacer()
            if model.running {
                Menu(L("プロファイル")) {
                    Button(L("自動切り替え")) { model.send(ServiceCommand("pin")) }
                    Divider()
                    ForEach(model.savedConfiguration.profiles.filter(\.enabled)) { profile in
                        Button(profile.name) { model.send(ServiceCommand("pin", id: profile.id)) }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Button(model.paused ? L("再開") : L("一時停止"), action: model.togglePause).buttonStyle(.borderless)
            } else {
                if !model.demonstration { Button(L("サービスを起動"), action: model.startService).buttonStyle(.borderless) }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func profileText(_ path: WritableKeyPath<StudioProfile, String>) -> Binding<String> {
        Binding(get: { model.profile?[keyPath: path] ?? "" }, set: { value in model.editProfile { $0[keyPath: path] = value } })
    }

    private func text(_ path: WritableKeyPath<StudioBinding, String>, in binding: StudioBinding) -> Binding<String> {
        Binding(get: { binding[keyPath: path] }, set: { value in model.updateBinding(binding.id) { $0[keyPath: path] = value } })
    }

    private func value<T: Equatable>(_ path: WritableKeyPath<StudioBinding, T>, in binding: StudioBinding) -> Binding<T> {
        Binding(get: { binding[keyPath: path] }, set: { value in model.updateBinding(binding.id) { $0[keyPath: path] = value } })
    }

    private func actionText(_ binding: StudioBinding, action: StudioAction, stepID: UUID?) -> Binding<String> {
        Binding(get: { action.value }, set: { value in model.updateAction(binding.id, stepID: stepID) { $0.value = value } })
    }

    private func symbol(for type: ActionType) -> String {
        switch type {
        case .none: return "minus.circle"
        case .block: return "nosign"
        case .switchLayer: return "square.stack"
        case .cycleLayer: return "arrow.right"
        case .previousPage: return "arrow.left"
        case .overlayHold, .overlayToggle: return "square.stack.3d.up"
        case .switchProfile, .cycleProfile, .automaticProfile: return "person.crop.rectangle.stack"
        case .shortcut: return "keyboard"
        case .scroll: return "arrow.up.arrow.down"
        case .media: return "speaker.wave.2"
        case .midi: return "pianokeys"
        case .shell: return "terminal"
        case .appleScript: return "applescript"
        case .browserScript: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func actionTitle(_ action: StudioAction) -> String {
        if action.type == .none { return L("未設定") }
        return ActionTemplate.all.first { $0.action.type == action.type && (action.value.isEmpty || $0.action.value == action.value) }?.title ?? action.type.title
    }
}

private struct ProfileApplicationIcon: View {
    let bundleID: String
    let iconData: Data?
    private static let cache = NSCache<NSString, NSImage>()
    private static let imageCache = NSCache<NSData, NSImage>()

    private var icon: NSImage? {
        if let iconData {
            if let cached = Self.imageCache.object(forKey: iconData as NSData) { return cached }
            if let image = NSImage(data: iconData) {
                Self.imageCache.setObject(image, forKey: iconData as NSData)
                return image
            }
        }
        guard !bundleID.isEmpty else { return nil }
        if let cached = Self.cache.object(forKey: bundleID as NSString) { return cached }
        let workspace = NSWorkspace.shared
        let image = workspace.runningApplications.first { $0.bundleIdentifier == bundleID }?.icon
            ?? workspace.urlForApplication(withBundleIdentifier: bundleID).map { workspace.icon(forFile: $0.path) }
        if let image { Self.cache.setObject(image, forKey: bundleID as NSString) }
        return image
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: bundleID.isEmpty ? "square.grid.2x2" : "app")
                .foregroundStyle(.secondary)
        }
    }
}
