import SwiftUI
import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import ImageIO
import UlanziKit

struct Activity: Identifiable {
    let id = UUID()
    let time = Date()
    let category: String
    let text: String
}
@Observable final class StudioModel {
    var configuration: StudioConfiguration
    /// Last state written to disk. `dirty` is derived so direct edits through
    /// bindings are also detected without observing every mutation.
    private(set) var savedConfiguration: StudioConfiguration
    var dirty: Bool { configuration != savedConfiguration }
    var selectedProfile: UUID?
    var selectedPage: UUID?
    var selectedLayer: UUID?
    var selectedBinding: UUID?
    var selectedControl: Control = .dial
    var activities: [Activity] = []
    var state = ServiceMessage("state", text: L("停止中"))
    var running = false
    var paused = false
    var error: String?
    var plugins: [InstalledPlugin] = []
    var pluginErrors: [String] = []
    var pluginTemplates: [ActionTemplate] { PluginRegistry.templates(plugins) }
    var actionTemplates: [ActionTemplate] { ActionTemplate.all + pluginTemplates }
    func template(for payload: String) -> ActionTemplate? { actionTemplates.first { $0.payload == payload } }
    func refreshPlugins() {
        let result = PluginRegistry.scan()
        plugins = result.plugins; pluginErrors = result.errors
    }
    func openPluginsFolder() {
        do {
            try FileManager.default.createDirectory(at: PluginRegistry.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(PluginRegistry.directory)
        } catch { self.error = String(describing: error) }
    }
    func installPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plugin = try PluginRegistry.load(url)
            refreshPlugins()
            guard !plugins.contains(where: { $0.manifest.id == plugin.manifest.id }) else { throw ConfigError("同じIDのプラグインが既にあります") }
            try FileManager.default.createDirectory(at: PluginRegistry.directory, withIntermediateDirectories: true)
            let destination = PluginRegistry.directory.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ConfigError("同じ名前のプラグインが既にあります") }
            try FileManager.default.copyItem(at: url, to: destination)
            refreshPlugins()
        } catch { self.error = String(describing: error) }
    }
    func removePlugin(_ plugin: InstalledPlugin) {
        guard plugin.directory.deletingLastPathComponent().standardizedFileURL == PluginRegistry.directory.standardizedFileURL else { return }
        do {
            try FileManager.default.trashItem(at: plugin.directory, resultingItemURL: nil)
            refreshPlugins()
        } catch { self.error = String(describing: error) }
    }
    var helperBusy = false
    var showSettings = false
    var showLog = false
    var hoveredDropTarget: String?
    weak var undoManager: UndoManager?
    var previewName = ""
    var previewOverlayIDs: [UUID] = []
    var previewHeld = Set<Control>()
    var deviceHeld = Set<Control>()
    var knobAngle: Double = 0
    var previewModifiers = Set<KeyModifier>()
    var calibrating: Control?
    var lastVendorButton: Int?
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var onLayerChange: ((String) -> Void)?
    var onMenuBarModeChange: ((Bool) -> Void)?
    let configURL: URL
    let demonstration: Bool
    private var process: Process?
    private var input: Pipe?
    private var engine: LayerEngine?
    private var previewDirty = true
    private var previewConfiguration: StudioConfiguration?
    private var clock: TimeInterval = 0
    private var stopping = false
    private var reportedAccessibilityError = false
    init(url: URL, demonstration: Bool = false) {
        configURL = url; self.demonstration = demonstration
        var initial = StudioConfiguration.starter
        var loadError: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do { initial = try StudioConfiguration.load(from: url) }
            catch { loadError = LF("設定を読み込めません。元のファイルは保持しています。\n%@", String(describing: error)) }
        }
        configuration = initial
        savedConfiguration = initial
        selectedProfile = initial.profiles.first?.id; selectedPage = initial.profiles.first?.pages.first?.id; selectedLayer = initial.profiles.first?.pages.first?.layers.first?.id
        selectedBinding = initial.profiles.first?.pages.first?.layers.first?.bindings.first?.id
        error = loadError
        refreshPlugins()
        if demonstration { log("preview", L("プレビューは外部アプリを操作しません。入力条件とレイヤー遷移を試せます。")) }
    }
    var profileIndex: Int? { configuration.profiles.firstIndex { $0.id == selectedProfile } }
    var profile: StudioProfile? { profileIndex.map { configuration.profiles[$0] } }
    var pageIndex: Int? { profile?.pages.firstIndex { $0.id == selectedPage } }
    var page: StudioPage? { pageIndex.flatMap { profile?.pages[$0] } }
    var pageOverlays: [StudioLayer] { Array(page?.layers.dropFirst() ?? []) }
    var layerIndex: Int? { page?.layers.firstIndex { $0.id == selectedLayer } }
    var layer: StudioLayer? { layerIndex.flatMap { page?.layers[$0] } }
    var layerIsAboveBottom: Bool { (layerIndex ?? 0) > 0 }
    var bindingIndex: Int? { layer?.bindings.firstIndex { $0.id == selectedBinding } }
    var binding: StudioBinding? { bindingIndex.flatMap { layer?.bindings[$0] } }
    func log(_ category: String, _ text: String) {
        activities.insert(Activity(category: category, text: String(text.prefix(4000))), at: 0)
        if activities.count > 150 { activities.removeLast(activities.count - 150) }
    }
    func selectProfile(_ id: UUID) {
        selectedProfile = id; selectedPage = profile?.pages.first?.id; selectedLayer = page?.layers.first?.id
        selectedBinding = nil; previewDirty = true; previewOverlayIDs = []
    }
    func selectPage(_ id: UUID) {
        guard let item = profile?.pages.first(where: { $0.id == id }) else { return }
        selectedPage = id; selectedLayer = item.layers.first?.id; selectedBinding = nil
        previewDirty = true; previewOverlayIDs = []
    }
    func selectLayer(_ id: UUID) {
        guard page?.layers.contains(where: { $0.id == id }) == true else { return }
        selectedLayer = id; selectedBinding = nil; previewDirty = true; previewOverlayIDs = []
    }
    func editProfile(_ update: (inout StudioProfile) -> Void) {
        guard let i = profileIndex else { return }; update(&configuration.profiles[i])
    }
    func setProfileApplication(_ bundleID: String) {
        editProfile {
            if $0.bundleID != bundleID { $0.host = "" }
            $0.bundleID = bundleID
        }
    }
    func chooseProfileApplication() {
        let panel = NSOpenPanel()
        panel.message = L("プロファイルを切り替えるアプリを選択してください。")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty else {
            error = LF("選択したアプリの識別子を取得できません: %@", url.lastPathComponent); return
        }
        setProfileApplication(identifier)
    }
    func chooseProfileIcon() {
        let panel = NSOpenPanel()
        panel.message = L("プロファイルに使用する画像を選択してください。")
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 128]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            error = LF("選択した画像を読み込めません: %@", url.lastPathComponent); return
        }
        editProfile { $0.iconData = data }
    }
    func moveProfiles(from offsets: IndexSet, to destination: Int) {
        configuration.profiles.move(fromOffsets: offsets, toOffset: destination)
    }
    func shiftProfile(_ id: UUID, by delta: Int) {
        guard let index = configuration.profiles.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard configuration.profiles.indices.contains(target) else { return }
        configuration.profiles.swapAt(index, target)
    }
    func editLayer(_ update: (inout StudioLayer) -> Void) {
        guard let p = profileIndex, let q = pageIndex, let l = layerIndex else { return }; update(&configuration.profiles[p].pages[q].layers[l])
    }
    func editBinding(_ update: (inout StudioBinding) -> Void) {
        guard let p = profileIndex, let q = pageIndex, let l = layerIndex, let b = bindingIndex else { return }
        update(&configuration.profiles[p].pages[q].layers[l].bindings[b])
    }
    func addProfile() { let p = StudioProfile(); configuration.profiles.append(p); selectProfile(p.id) }
    private func copyPages(_ pages: [StudioPage], oldProfile: UUID? = nil, newProfile: UUID? = nil) -> [StudioPage] {
        let allIDs = pages.map(\.id) + pages.flatMap(\.layers).map(\.id)
        let ids = Dictionary(uniqueKeysWithValues: allIDs.map { ($0, UUID()) })
        return pages.map { original in
            var page = original; page.id = ids[original.id]!
            for l in page.layers.indices {
                page.layers[l].id = ids[page.layers[l].id]!
                for b in page.layers[l].bindings.indices {
                    page.layers[l].bindings[b].id = UUID()
                    func remap(_ action: inout StudioAction) {
                        if let target = action.targetLayer, let replacement = ids[target] { action.targetLayer = replacement }
                        if let oldProfile, action.targetProfile == oldProfile { action.targetProfile = newProfile }
                    }
                    remap(&page.layers[l].bindings[b].action)
                    if let count = page.layers[l].bindings[b].steps?.count { for i in 0..<count {
                        page.layers[l].bindings[b].steps![i].id = UUID()
                        remap(&page.layers[l].bindings[b].steps![i].action)
                    } }
                }
            }
            return page
        }
    }
    func duplicateProfile() {
        guard var p = profile else { return }
        let old = p.id; p.id = UUID(); p.name += L(" コピー")
        p.pages = copyPages(p.pages, oldProfile: old, newProfile: p.id)
        configuration.profiles.append(p); selectProfile(p.id)
    }
    func deleteProfile() {
        guard let id = selectedProfile else { return }
        configuration.profiles.removeAll { $0.id == id }
        for p in configuration.profiles.indices { for q in configuration.profiles[p].pages.indices { for l in configuration.profiles[p].pages[q].layers.indices { for b in configuration.profiles[p].pages[q].layers[l].bindings.indices {
            var binding = configuration.profiles[p].pages[q].layers[l].bindings[b]
            binding.steps?.removeAll { $0.action.type == .switchProfile && $0.action.targetProfile == id }
            if binding.action.type == .switchProfile && binding.action.targetProfile == id {
                if let first = binding.steps?.first { binding.action = first.action; binding.steps?.removeFirst() }
                else { binding.action = StudioAction() }
            }
            if binding.steps?.isEmpty == true { binding.steps = nil }
            configuration.profiles[p].pages[q].layers[l].bindings[b] = binding
        } } } }
        if let next = configuration.profiles.first { selectProfile(next.id) } else { selectedProfile = nil; selectedPage = nil; selectedLayer = nil }
    }
    func addLayer() {
        let page = StudioPage(); editProfile { $0.pages.append(page) }; selectPage(page.id)
    }
    func addOverlay() {
        guard let p = profileIndex, let q = pageIndex else { return }
        let layer = StudioLayer(); configuration.profiles[p].pages[q].layers.append(layer); selectLayer(layer.id)
    }
    func renamePage(_ id: UUID, profileID: UUID, name: String) {
        guard let p = configuration.profiles.firstIndex(where: { $0.id == profileID }), let q = configuration.profiles[p].pages.firstIndex(where: { $0.id == id }) else { return }
        let previous = configuration; configuration.profiles[p].pages[q].name = name
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
        undoManager?.setActionName(L("ページ名を変更"))
    }
    func renameLayer(_ id: UUID, profileID: UUID, name: String) {
        guard let p = configuration.profiles.firstIndex(where: { $0.id == profileID }), let q = configuration.profiles[p].pages.firstIndex(where: { $0.layers.contains(where: { $0.id == id }) }), let l = configuration.profiles[p].pages[q].layers.firstIndex(where: { $0.id == id }) else { return }
        let previous = configuration; configuration.profiles[p].pages[q].layers[l].name = name
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
        undoManager?.setActionName(L("レイヤー名を変更"))
    }
    func duplicatePage() {
        guard let page else { return }; var copy = copyPages([page])[0]; copy.name += L(" コピー")
        editProfile { $0.pages.append(copy) }; selectPage(copy.id)
    }
    func duplicateLayer() {
        guard let layer, let p = profileIndex, let q = pageIndex else { return }
        var copy = layer; copy.id = UUID(); copy.name += L(" コピー")
        for i in copy.bindings.indices { copy.bindings[i].id = UUID(); if let n = copy.bindings[i].steps?.count { for j in 0..<n { copy.bindings[i].steps![j].id = UUID() } } }
        configuration.profiles[p].pages[q].layers.append(copy); selectLayer(copy.id)
    }
    private func removeReferences(to ids: Set<UUID>, fallbackPage: UUID?) {
        for p in configuration.profiles.indices { for q in configuration.profiles[p].pages.indices { for l in configuration.profiles[p].pages[q].layers.indices { for b in configuration.profiles[p].pages[q].layers[l].bindings.indices {
            var binding = configuration.profiles[p].pages[q].layers[l].bindings[b]
            func adjust(_ action: inout StudioAction) -> Bool {
                guard let id = action.targetLayer, ids.contains(id) else { return true }
                if action.type == .switchLayer, let fallbackPage { action.targetLayer = fallbackPage; return true }
                return false
            }
            if let steps = binding.steps {
                binding.steps = steps.compactMap { step in var step = step; return adjust(&step.action) ? step : nil }
            }
            if !adjust(&binding.action) {
                if let first = binding.steps?.first { binding.action = first.action; binding.steps?.removeFirst() }
                else { binding.action = StudioAction() }
            }
            if binding.steps?.isEmpty == true { binding.steps = nil }
            configuration.profiles[p].pages[q].layers[l].bindings[b] = binding
        } } } }
    }
    func deletePage() {
        guard let p = profileIndex, let q = pageIndex, configuration.profiles[p].pages.count > 1 else { return }
        let removed = configuration.profiles[p].pages.remove(at: q)
        let fallback = configuration.profiles[p].pages.first!.id
        removeReferences(to: Set([removed.id] + removed.layers.map(\.id)), fallbackPage: fallback)
        selectPage(fallback)
    }
    func deleteLayer() {
        guard let p = profileIndex, let q = pageIndex, let l = layerIndex, configuration.profiles[p].pages[q].layers.count > 1 else { return }
        let removed = configuration.profiles[p].pages[q].layers.remove(at: l)
        removeReferences(to: [removed.id], fallbackPage: nil)
        selectLayer(configuration.profiles[p].pages[q].layers.first!.id)
    }
    func movePage(_ id: UUID, before target: UUID) {
        guard let p = profileIndex, let from = configuration.profiles[p].pages.firstIndex(where: { $0.id == id }), let to = configuration.profiles[p].pages.firstIndex(where: { $0.id == target }), from != to else { return }
        let old = configuration; let item = configuration.profiles[p].pages.remove(at: from); configuration.profiles[p].pages.insert(item, at: to)
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(old) }
    }
    func shiftPage(_ id: UUID, by delta: Int) {
        guard let p = profileIndex, let i = configuration.profiles[p].pages.firstIndex(where: { $0.id == id }), configuration.profiles[p].pages.indices.contains(i + delta) else { return }
        configuration.profiles[p].pages.swapAt(i, i + delta)
    }
    func moveLayer(_ id: UUID, before target: UUID) {
        guard let p = profileIndex, let q = pageIndex, let from = configuration.profiles[p].pages[q].layers.firstIndex(where: { $0.id == id }), let to = configuration.profiles[p].pages[q].layers.firstIndex(where: { $0.id == target }), from != to else { return }
        let previous = configuration
        let layer = configuration.profiles[p].pages[q].layers.remove(at: from)
        configuration.profiles[p].pages[q].layers.insert(layer, at: to)
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
        undoManager?.setActionName(L("レイヤーを移動"))
    }
    func shiftLayer(_ id: UUID, by delta: Int) {
        guard let p = profileIndex, let q = pageIndex, let i = configuration.profiles[p].pages[q].layers.firstIndex(where: { $0.id == id }), configuration.profiles[p].pages[q].layers.indices.contains(i + delta) else { return }
        configuration.profiles[p].pages[q].layers.swapAt(i, i + delta)
    }
    func addBinding() {
        guard let layer else { return }
        let used = Set(layer.bindings.filter { $0.control == selectedControl && $0.enabled && $0.held.isEmpty && $0.modifiers.isEmpty }.map(\.gesture))
        let candidates: [GestureKind] = selectedControl == .dial ? [.clockwise, .counterclockwise, .pressedClockwise, .pressedCounterclockwise] : [.press, .tap, .hold, .release, .holdRelease]
        guard let gesture = candidates.first(where: { !used.contains($0) }) else {
            error = L("この入力の操作はすべて割り当て済みです。既存の割り当てにアクションを追加してください。")
            return
        }
        let b = StudioBinding(control: selectedControl, gesture: gesture)
        editLayer { $0.bindings.append(b) }; selectedBinding = b.id
    }
    func deleteBinding() { guard let id = selectedBinding else { return }; editLayer { $0.bindings.removeAll { $0.id == id } }; selectedBinding = nil }
    func deleteBinding(_ id: UUID) {
        editLayer { $0.bindings.removeAll { $0.id == id } }
        if selectedBinding == id { selectedBinding = nil }
    }
    @discardableResult func moveTimelineBinding(_ id: UUID, to gesture: GestureKind) -> Bool {
        guard let current = layer?.bindings.first(where: { $0.id == id }),
              current.control == selectedControl, !gesture.isRotation, current.gesture != gesture else { return false }
        let hasContinuous = current.action.type == .overlayHold || (current.steps ?? []).contains { $0.action.type == .overlayHold }
        if hasContinuous && ![.press, .hold].contains(gesture) {
            error = L("継続アクションは「押した時」か「長押し成立時」に追加してください"); return false
        }
        if current.enabled && (layer?.bindings.contains { $0.id != id && $0.enabled && $0.control == current.control && $0.gesture == gesture && $0.held == current.held && $0.modifiers == current.modifiers } ?? false) {
            error = L("移動先に同じ入力条件の割り当てがあります。"); return false
        }
        let previous = configuration
        updateBinding(id) { $0.gesture = gesture }
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
        undoManager?.setActionName(L("タイミングを移動"))
        return true
    }
    func updateBinding(_ id: UUID, _ change: (inout StudioBinding) -> Void) {
        guard let p = profileIndex, let q = pageIndex, let l = layerIndex,
              let i = configuration.profiles[p].pages[q].layers[l].bindings.firstIndex(where: { $0.id == id }) else { return }
        change(&configuration.profiles[p].pages[q].layers[l].bindings[i])
    }
    func updateAction(_ bindingID: UUID, stepID: UUID?, _ change: (inout StudioAction) -> Void) {
        updateBinding(bindingID) { binding in
            if let stepID, let index = binding.steps?.firstIndex(where: { $0.id == stepID }) {
                change(&binding.steps![index].action)
            } else if stepID == nil { change(&binding.action) }
        }
    }
    @discardableResult func appendAction(_ payloads: [String], binding: StudioBinding) -> Bool {
        guard payloads.count == 1, let template = template(for: payloads[0]), let p = selectedProfile, let l = selectedLayer else { return false }
        do {
            let previous = configuration
            var updated = configuration
            try updated.append(template, profileID: p, layerID: l, bindingID: binding.id)
            undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
            undoManager?.setActionName(L("アクションを追加"))
            configuration = updated
            return true
        } catch { self.error = String(describing: error); return false }
    }
    func removeAction(_ bindingID: UUID, stepID: UUID?) {
        updateBinding(bindingID) { binding in
            if let stepID { binding.steps?.removeAll { $0.id == stepID } }
            else if let first = binding.steps?.first { binding.action = first.action; binding.steps?.removeFirst() }
            else { binding.action = StudioAction() }
            if binding.steps?.isEmpty == true { binding.steps = nil }
        }
    }
    func moveAction(_ bindingID: UUID, stepID: UUID?, by delta: Int) {
        updateBinding(bindingID) { binding in
            var actions = [binding.action] + (binding.steps ?? []).map(\.action)
            let index = stepID.flatMap { id in binding.steps?.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? 0
            let target = index + delta
            guard actions.indices.contains(target) else { return }
            actions.swapAt(index, target); binding.action = actions[0]
            if let count = binding.steps?.count { for i in 0..<count { binding.steps![i].action = actions[i + 1] } }
        }
    }
    @discardableResult func moveAction(_ bindingID: UUID, from source: Int, to target: Int) -> Bool {
        guard let binding = layer?.bindings.first(where: { $0.id == bindingID }), binding.action.type != .none else { return false }
        let count = 1 + (binding.steps?.count ?? 0)
        guard (0..<count).contains(source), (0..<count).contains(target), source != target else { return false }
        let previous = configuration
        updateBinding(bindingID) { binding in
            var actions = [binding.action] + (binding.steps ?? []).map(\.action)
            let action = actions.remove(at: source)
            actions.insert(action, at: target)
            binding.action = actions[0]
            if let count = binding.steps?.count { for i in 0..<count { binding.steps![i].action = actions[i + 1] } }
        }
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
        undoManager?.setActionName(L("アクションの順序を変更"))
        return true
    }
    func assignmentPayload(_ control: Control, gesture: GestureKind? = nil) -> String? {
        guard let p = selectedProfile, let l = selectedLayer,
              layer?.bindings.contains(where: { $0.control == control && (gesture == nil || $0.gesture == gesture) }) == true else { return nil }
        return "dialstudio/assignment/\(p.uuidString)/\(l.uuidString)/\(control.rawValue)/\(gesture?.rawValue ?? "all")"
    }
    private func swapAssignments(_ payload: String, to control: Control, gesture: GestureKind?) -> Bool {
        let parts = payload.split(separator: "/").map(String.init)
        guard parts.count == 6, parts[0] == "dialstudio", parts[1] == "assignment",
              UUID(uuidString: parts[2]) == selectedProfile, UUID(uuidString: parts[3]) == selectedLayer,
              let source = Control(rawValue: parts[4]), let p = profileIndex, let q = pageIndex, let l = layerIndex else { return false }
        let sourceGesture = parts[5] == "all" ? nil : GestureKind(rawValue: parts[5])
        guard (source != .dial && control != .dial && sourceGesture == nil && gesture == nil && source != control)
                || (source == .dial && control == .dial && sourceGesture != nil && gesture != nil && sourceGesture != gesture) else { return false }
        var bindings = configuration.profiles[p].pages[q].layers[l].bindings
        var changed = false
        for i in bindings.indices {
            if bindings[i].control == source && (sourceGesture == nil || bindings[i].gesture == sourceGesture) {
                if source == .dial { bindings[i].gesture = gesture! }
                else { bindings[i].control = control }
                changed = true
            } else if bindings[i].control == control && (gesture == nil || bindings[i].gesture == gesture) {
                if control == .dial { bindings[i].gesture = sourceGesture! }
                else { bindings[i].control = source }
            }
        }
        guard changed else { return false }
        guard bindings.allSatisfy({ !$0.held.contains($0.control) }) else {
            error = L("入れ替えると、同じボタンを押しながらそのボタンを操作する条件になります。条件を変更してください。")
            return false
        }
        let previous = configuration
        configuration.profiles[p].pages[q].layers[l].bindings = bindings
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(previous) }
        undoManager?.setActionName(L("割り当てを入れ替え"))
        selectedControl = control; selectedBinding = bindings.first { $0.control == control && (gesture == nil || $0.gesture == gesture) }?.id
        hoveredDropTarget = nil
        return true
    }
    func bindings(for control: Control) -> [StudioBinding] {
        (layer?.bindings ?? []).filter { $0.control == control }
    }
    @discardableResult func assignDrop(_ payloads: [String], to control: Control, gesture: GestureKind? = nil) -> Bool {
        if payloads.count == 1, payloads[0].hasPrefix("dialstudio/assignment/") {
            return swapAssignments(payloads[0], to: control, gesture: control == .dial ? gesture : nil)
        }
        guard payloads.count == 1, let template = template(for: payloads[0]), let p = selectedProfile, let l = selectedLayer else { return false }
        do {
            let old = configuration
            var updated = configuration
            let change = try updated.assign(template, profileID: p, layerID: l, control: control, gesture: gesture)
            undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(old) }
            undoManager?.setActionName(L("割り当てを変更"))
            configuration = updated; selectedControl = control; selectedBinding = change.bindingID
            hoveredDropTarget = nil
            log("edit", LF("%@に「%@」を%@ました。保存すると反映されます。", control.title, template.title, L(change.replaced ? "置き換え" : "追加")))
            return true
        } catch { self.error = String(describing: error); return false }
    }
    private func restoreConfiguration(_ previous: StudioConfiguration) {
        let current = configuration
        undoManager?.registerUndo(withTarget: self) { $0.restoreConfiguration(current) }
        configuration = previous
        if binding == nil { selectedBinding = layer?.bindings.first { $0.control == selectedControl }?.id }
    }
    func save() {
        do {
            try configuration.save(to: configURL)
            savedConfiguration = configuration
            log("saved", L("設定を保存しました"))
            if running { send(ServiceCommand("reload")) }
        } catch { self.error = String(describing: error) }
    }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Dial Studio.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try configuration.save(to: url) } catch { self.error = String(describing: error) }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            configuration = try StudioConfiguration.load(from: url)
            onMenuBarModeChange?(configuration.menuBarOnly)
            if let p = configuration.profiles.first { selectProfile(p.id) }
            log("import", L("読み込みました。保存・反映するまでサービスの設定は変わりません。"))
        } catch { self.error = String(describing: error) }
    }
    var helperURL: URL { Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("ulanzid") }
    func startService() {
        guard !running, !demonstration else { return }
        if !FileManager.default.fileExists(atPath: configURL.path) { save() }
        do {
            _ = try StudioConfiguration.load(from: configURL)
            let p = Process(); let stdin = Pipe(); let stdout = Pipe()
            p.executableURL = helperURL
            let language = Bundle.main.preferredLocalizations.first ?? "ja"
            p.arguments = ["serve", "--config", configURL.path, "-AppleLanguages", "(\(language))"]
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stdout
            stopping = false; reportedAccessibilityError = false
            p.terminationHandler = { [weak self] process in DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.running = false; self.state = ServiceMessage("state", text: L("停止中")); self.process = nil; self.input = nil
                self.log("service", LF("サービス終了 (%d)", process.terminationStatus))
            }}
            try p.run(); process = p; input = stdin; running = true; paused = false
            Thread { [weak self] in
                var pending = Data()
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }; pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        let message = try? JSONDecoder().decode(ServiceMessage.self, from: line)
                        let raw = String(decoding: line, as: UTF8.self)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.process === p else { return }
                            if let message { self.receive(message) } else if !raw.isEmpty { self.log("service", raw) }
                        }
                    }
                    if pending.count > 262144 { pending.removeAll() }
                }
                try? stdout.fileHandleForReading.close()
            }.start()
        } catch { self.error = LF("サービスを起動できません: %@", String(describing: error)) }
    }
    func send(_ command: ServiceCommand) {
        guard let input, process?.isRunning == true, var data = try? JSONEncoder().encode(command) else { return }
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { log("error", LF("サービスへの送信に失敗: %@", String(describing: error))) }
    }
    func stopService() {
        guard let p = process else { return }; stopping = true; send(ServiceCommand("quit"))
        try? input?.fileHandleForWriting.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
    }
    func togglePause() { paused.toggle(); send(ServiceCommand(paused ? "pause" : "resume")) }
    private func receive(_ message: ServiceMessage) {
        if message.kind == "state" {
            let changed = state.layerID != message.layerID || state.profileID != message.profileID
            state = message
            if message.connected != true { deviceHeld.removeAll() }
            if changed && configuration.showHUD && message.connected == true { onLayerChange?("\(message.profileName ?? "")  /  \(message.layerName ?? "")") }
        } else if message.kind == "calibration" {
            lastVendorButton = message.vendorButton
            if message.vendorDown == true, let physical = calibrating, let number = message.vendorButton {
                configuration.vendorLayout = configuration.vendorLayout.filter { $0.value != physical }
                configuration.vendorLayout[String(number)] = physical; calibrating = nil
                log("calibration", LF("ボタン %d → %@。保存・反映してください。", number, physical.title))
            }
        } else if message.kind == "input", let event = message.controlEvent {
            if event.phase == .down { deviceHeld.insert(event.control) }
            if event.phase == .up { deviceHeld.remove(event.control) }
            if event.phase == .rotate { knobAngle = (knobAngle + Double(event.delta) * 12).truncatingRemainder(dividingBy: 360) }
            log("input", "\(event.control.title) · \(event.phase.rawValue) \(event.delta == 0 ? "" : String(event.delta))")
        } else if let text = message.text {
            let displayed = ["error", "device", "ready", "saved"].contains(message.kind) ? L(text) : text
            log(message.kind, displayed)
            if message.kind == "error", (text.contains("アクセシビリティ許可が必要") || text.localizedCaseInsensitiveContains("Accessibility access is required")), !reportedAccessibilityError {
                reportedAccessibilityError = true
                error = displayed + L("\nシステム設定の「プライバシーとセキュリティ」→「アクセシビリティ」で Dial Studio を許可してください。")
            }
        }
    }
    func startHelper() {
        guard configuration.mode.usesHelper, !helperBusy else { return }
        do { try configuration.validate() } catch { self.error = String(describing: error); return }
        save(); if dirty { return }; if !running { startService() }
        helperBusy = true
        let command = ProcessRunner.shellQuote(helperURL.path) + " hidd --owner \(getuid()) --parent \(getpid())" + (configuration.mode == .exclusiveVendor ? " --vendor" : "")
        // The admin process runs only this HID broker, with no scripts or profile arguments.
        let launch = "log=$(/usr/bin/mktemp /var/run/dialstudio.XXXXXX) || exit 1; trap '/bin/rm -f \"$log\"' EXIT; " + command + " >\"$log\" 2>&1 & child=$!; /bin/sleep 0.4; if /bin/kill -0 \"$child\" 2>/dev/null; then /bin/echo started; else /bin/cat \"$log\"; exit 1; fi"
        let script = "do shell script " + ProcessRunner.appleLiteral(launch) + " with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ProcessRunner.checked("/usr/bin/osascript", ["-e", script], timeout: 120) }
            DispatchQueue.main.async {
                guard let self else { return }; self.helperBusy = false
                switch result {
                case .success: self.log("device", L("HIDヘルパーを起動しました。実機の接続応答を待っています。"))
                case .failure(let error): self.error = LF("ヘルパー起動: %@", String(describing: error))
                }
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
        catch { self.error = LF("ログイン時の起動: %@", String(describing: error)) }
    }
    func resetPreview() { previewDirty = true; preparePreview() }
    private func preparePreview() {
        guard previewDirty || engine == nil || previewConfiguration != configuration else { return }
        let e = LayerEngine(configuration); e.pinnedProfileID = selectedProfile
        e.updateContext(AppContext(bundleID: profile?.bundleID ?? "", appName: profile?.name ?? "", url: profile?.host.isEmpty == false ? "https://\(profile!.host)/" : ""))
        if let selectedPage { e.selectLayer(selectedPage) }
        e.onAction = { [weak self, weak e] call in
            self?.log("preview", "\(call.layer.name) → \(call.binding.name) · \(call.binding.action.summary)")
            if let steps = call.binding.steps, !steps.isEmpty {
                for action in [call.binding.action] + steps.map(\.action) {
                    if action.type.isLayer || action.type.isProfile { _ = e?.applyStateAction(action, control: call.binding.control, pressID: call.pressID, sourceLayerID: call.layer.id) }
                }
                self?.log("preview", LF("連続アクション %d 件（プレビューでは待ち時間を省略）", steps.count + 1))
            }
        }
        engine = e; previewDirty = false; previewConfiguration = configuration
        previewHeld = []; clock = 0; updatePreviewState(e)
    }
    func simulate(_ event: ControlEvent) {
        preparePreview(); clock += 0.01
        if event.phase == .rotate { knobAngle = (knobAngle + Double(event.delta) * 12).truncatingRemainder(dividingBy: 360) }
        engine?.handle(event, modifiers: previewModifiers, now: clock)
        if let engine { updatePreviewState(engine) }
    }
    private func updatePreviewState(_ engine: LayerEngine) {
        previewHeld = engine.pressed
        previewOverlayIDs = engine.activeOverlays.map(\.id)
        previewName = ([engine.layer?.name ?? "—"] + engine.activeOverlays.map(\.name)).joined(separator: " + ")
    }
    func tap(_ control: Control, long: Bool = false) {
        simulate(ControlEvent(control, .down))
        if long { clock += Double(configuration.holdMilliseconds) / 1000 + 0.1; engine?.advance(now: clock, modifiers: previewModifiers) }
        simulate(ControlEvent(control, .up))
    }
}
