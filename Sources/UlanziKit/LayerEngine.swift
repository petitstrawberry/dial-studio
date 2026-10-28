import Foundation

public struct AppContext: Codable, Equatable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var url: String
    public init(bundleID: String = "", appName: String = "", title: String = "", url: String = "") {
        self.bundleID = bundleID; self.appName = appName; self.title = title; self.url = url
    }
}
public struct ControlEvent: Codable, Equatable {
    public enum Phase: String, Codable { case down, up, rotate }
    public var control: Control
    public var phase: Phase
    public var delta: Int
    /// The device reports press-and-rotate as a separate, instantaneous event.
    public var pressedRotation: Bool?
    public init(_ control: Control, _ phase: Phase, delta: Int = 0, pressedRotation: Bool = false) {
        self.control = control; self.phase = phase; self.delta = delta; self.pressedRotation = pressedRotation ? true : nil
    }
}
public struct ActionInvocation {
    public let binding: StudioBinding
    public let profile: StudioProfile
    public let layer: StudioLayer
    public let context: AppContext
    public let pressID: UUID?
    public init(binding: StudioBinding, profile: StudioProfile, layer: StudioLayer, context: AppContext, pressID: UUID? = nil) {
        self.binding = binding; self.profile = profile; self.layer = layer; self.context = context; self.pressID = pressID
    }
}
/// All state transitions run on one serial executor (the service's main queue).
/// No OS events are intercepted. The same pure engine powers the editor preview.
public final class LayerEngine {
    public private(set) var configuration: StudioConfiguration
    public private(set) var context = AppContext()
    public private(set) var profileID: UUID?
    public var pinnedProfileID: UUID?
    public var onAction: ((ActionInvocation) -> Void)?
    public var onChange: (() -> Void)?
    private var remembered: [UUID: UUID] = [:]
    private var enabledOverlays: [UUID: Set<UUID>] = [:]
    private var heldOverlays: [Control: Set<UUID>] = [:]
    private struct Down {
        let id: UUID
        let at: TimeInterval
        let pageID: UUID?
        let resolved: [GestureKind: ActionInvocation]
        var blocked = false
        var heldFired = false
    }
    private var down: [Control: Down] = [:]
    public init(_ configuration: StudioConfiguration) { self.configuration = configuration }
    public var profile: StudioProfile? { configuration.profiles.first { $0.id == profileID } }
    public var layer: StudioPage? {
        guard let profile else { return nil }
        let id = remembered[profile.id] ?? profile.pages.first?.id
        return profile.pages.first { $0.id == id } ?? profile.pages.first
    }
    /// Overlay order follows the configured list; the last overlay has priority.
    public var activeOverlays: [StudioLayer] {
        guard let profile, let page = layer else { return [] }
        let active = (enabledOverlays[profile.id] ?? []).union(heldOverlays.values.flatMap { $0 })
        return page.layers.dropFirst().filter { active.contains($0.id) }
    }
    public var pressed: Set<Control> { Set(down.keys) }
    public func reload(_ config: StudioConfiguration) {
        configuration = config
        cancelHeld()
        remembered = remembered.filter { p, l in config.profiles.contains { $0.id == p && $0.pages.contains { $0.id == l } } }
        enabledOverlays = enabledOverlays.reduce(into: [:]) { result, entry in
            guard let p = config.profiles.first(where: { $0.id == entry.key }) else { return }
            result[entry.key] = entry.value.intersection(p.pages.flatMap(\.layers).map(\.id))
        }
        updateContext(context)
        onChange?()
    }
    public func updateContext(_ context: AppContext) {
        self.context = context
        if let id = pinnedProfileID, !configuration.profiles.contains(where: { $0.id == id && $0.enabled }) { pinnedProfileID = nil }
        let selected = configuration.profiles.first { $0.id == pinnedProfileID && $0.enabled } ?? Self.match(configuration.profiles, context)
        if selected?.id != profileID {
            cancelHeld(); profileID = selected?.id; onChange?()
        }
    }
    public static func match(_ profiles: [StudioProfile], _ context: AppContext) -> StudioProfile? {
        let hostname = URL(string: context.url)?.host?.lowercased() ?? ""
        return profiles.enumerated().filter { _, p in
            guard p.enabled, p.bundleID.isEmpty || p.bundleID == context.bundleID else { return false }
            if let title = p.titleContains, !title.isEmpty, !context.title.localizedCaseInsensitiveContains(title) { return false }
            let wanted = p.host.lowercased()
            return wanted.isEmpty || hostname == wanted || hostname.hasSuffix("." + wanted)
        }.sorted { lhs, rhs in
            func rank(_ p: StudioProfile) -> Int { (p.bundleID.isEmpty ? 0 : 1) + (p.host.isEmpty ? 0 : 2) + ((p.titleContains ?? "").isEmpty ? 0 : 1) }
            return rank(lhs.element) == rank(rhs.element) ? lhs.offset < rhs.offset : rank(lhs.element) > rank(rhs.element)
        }.first?.element
    }
    public func selectLayer(_ id: UUID) {
        guard let profile, profile.pages.contains(where: { $0.id == id }) else { return }
        setPersistentLayer(id, profile: profile); onChange?()
    }
    private func setPersistentLayer(_ id: UUID, profile: StudioProfile) {
        guard let base = profile.pages.first else { return }
        if remembered[profile.id] ?? base.id != id { remembered[profile.id] = id }
    }
    public func cancelHeld() { down.removeAll(); heldOverlays.removeAll() }
    public func handle(_ event: ControlEvent, modifiers: Set<KeyModifier> = [], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch event.phase {
        case .down:
            guard event.control != .dial, down[event.control] == nil else { return }
            let id = UUID()
            var resolved: [GestureKind: ActionInvocation] = [:]
            for gesture in [GestureKind.press, .hold, .release, .tap, .holdRelease] {
                if let invocation = resolve(event.control, gesture, modifiers, pressID: id) { resolved[gesture] = invocation }
            }
            down[event.control] = Down(id: id, at: now, pageID: layer?.id, resolved: resolved)
            if let invocation = resolved[.press] {
                _ = dispatch(invocation)
                if invocation.binding.action.type == .block { down[event.control]?.blocked = true }
            }
        case .up:
            guard var state = down[event.control] else { return }
            let long = now - state.at >= Double(configuration.holdMilliseconds) / 1000
            if long && !state.heldFired && !state.blocked {
                state.heldFired = true; down[event.control]?.heldFired = true
                if let invocation = state.resolved[.hold] { _ = dispatch(invocation) }
            }
            let wasOverlay = heldOverlays.removeValue(forKey: event.control) != nil
            if wasOverlay { onChange?() }
            if !state.blocked {
                if let invocation = state.resolved[.release] { _ = dispatch(invocation) }
                if let invocation = state.resolved[long ? .holdRelease : .tap] { _ = dispatch(invocation) }
            }
            down.removeValue(forKey: event.control)
        case .rotate:
            guard event.control == .dial, event.delta != 0 else { return }
            let gesture: GestureKind
            if event.pressedRotation == true { gesture = event.delta > 0 ? .pressedClockwise : .pressedCounterclockwise }
            else { gesture = event.delta > 0 ? .clockwise : .counterclockwise }
            for _ in 0..<Int(min(event.delta.magnitude, 64)) { _ = fire(.dial, gesture, modifiers) }
        }
    }
    public func advance(now: TimeInterval = ProcessInfo.processInfo.systemUptime, modifiers: Set<KeyModifier> = []) {
        for control in Array(down.keys) {
            guard let state = down[control], !state.blocked, !state.heldFired,
                  now - state.at >= Double(configuration.holdMilliseconds) / 1000 else { continue }
            down[control]?.heldFired = true
            if let invocation = state.resolved[.hold] { _ = dispatch(invocation) }
        }
    }
    private func resolve(_ control: Control, _ gesture: GestureKind, _ modifiers: Set<KeyModifier>, pressID: UUID? = nil) -> ActionInvocation? {
        guard let profile, let page = layer else { return nil }
        let held = pressed.subtracting([control])
        func find(_ layer: StudioLayer) -> StudioBinding? {
            let matching = layer.bindings.enumerated().filter { _, b in
                b.enabled && b.control == control && b.gesture == gesture && b.held.isSubset(of: held) && b.modifiers == modifiers
            }.sorted { a, b in a.element.held.count == b.element.held.count ? a.offset < b.offset : a.element.held.count > b.element.held.count }.first?.element
            if let matching { return matching }
            guard control != .dial else { return nil }
            return layer.bindings.enumerated().filter { _, b in
                b.enabled && b.control == control && b.action.type == .block && b.held.isSubset(of: held) && b.modifiers == modifiers
            }.sorted { a, b in a.element.held.count == b.element.held.count ? a.offset < b.offset : a.element.held.count > b.element.held.count }.first?.element
        }
        guard let (source, binding) = (activeOverlays.reversed() + Array(page.layers.prefix(1))).lazy.compactMap({ candidate in
            find(candidate).map { (candidate, $0) }
        }).first else { return nil }
        return ActionInvocation(binding: binding, profile: profile, layer: source, context: context, pressID: pressID)
    }
    @discardableResult private func dispatch(_ invocation: ActionInvocation) -> Bool {
        let binding = invocation.binding
        if binding.action.type == .block { return true }
        if binding.steps?.isEmpty != false {
            guard applyStateAction(binding.action, control: binding.control, pressID: invocation.pressID, sourceLayerID: invocation.layer.id) else { return false }
        }
        onAction?(invocation)
        return true
    }
    @discardableResult private func fire(_ control: Control, _ gesture: GestureKind, _ modifiers: Set<KeyModifier>) -> Bool {
        guard let invocation = resolve(control, gesture, modifiers) else { return false }
        return dispatch(invocation)
    }
    public func isPressActive(_ id: UUID?, control: Control) -> Bool {
        guard let id else { return false }
        return down[control]?.id == id
    }

    /// State transitions are also callable by the serial sequence executor.
    @discardableResult public func applyStateAction(_ action: StudioAction, control: Control, pressID: UUID? = nil, sourceLayerID: UUID? = nil) -> Bool {
        guard let profile, let base = profile.pages.first else { return false }
        switch action.type {
        case .switchLayer:
            guard let id = action.targetLayer, profile.pages.contains(where: { $0.id == id }) else { return false }
            setPersistentLayer(id, profile: profile)
        case .cycleLayer, .previousPage:
            let pages = profile.pages
            let i = pages.firstIndex { $0.id == (remembered[profile.id] ?? base.id) } ?? 0
            let delta = action.type == .previousPage ? -1 : 1
            setPersistentLayer(pages[(i + delta + pages.count) % pages.count].id, profile: profile)
        case .overlayHold:
            guard let state = down[control], (pressID == nil || state.id == pressID),
                  let pageID = state.pageID, let page = profile.pages.first(where: { $0.id == pageID }),
                  let id = action.targetLayer, page.layers.contains(where: { $0.id == id }) else { return false }
            heldOverlays[control, default: []].insert(id)
        case .overlayToggle:
            guard let page = layer, let id = action.targetLayer, page.layers.contains(where: { $0.id == id }) else { return false }
            if enabledOverlays[profile.id, default: []].contains(id) { enabledOverlays[profile.id]?.remove(id) }
            else { enabledOverlays[profile.id, default: []].insert(id) }
        case .switchProfile:
            guard let id = action.targetProfile, configuration.profiles.contains(where: { $0.id == id && $0.enabled }) else { return false }
            pinnedProfileID = id; updateContext(context)
        case .cycleProfile:
            let available = configuration.profiles.filter(\.enabled)
            guard !available.isEmpty else { return false }
            let index = available.firstIndex { $0.id == profileID } ?? -1
            pinnedProfileID = available[(index + 1) % available.count].id; updateContext(context)
        case .automaticProfile:
            pinnedProfileID = nil; updateContext(context)
        default: break
        }
        if action.type.isLayer || action.type.isProfile { onChange?() }
        return true
    }
}
