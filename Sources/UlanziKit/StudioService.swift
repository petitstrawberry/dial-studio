import AppKit
import Foundation

public struct ServiceMessage: Codable {
    public var kind: String
    public var text: String?
    public var connected: Bool?
    public var profileID: UUID?
    public var layerID: UUID?
    public var profileName: String?
    public var profilePinned: Bool?
    public var layerName: String?
    public var activeOverlayIDs: [UUID]?
    public var context: AppContext?
    public var controlEvent: ControlEvent?
    public var vendorButton: Int?
    public var vendorDown: Bool?
    public init(_ kind: String, text: String? = nil) { self.kind = kind; self.text = text }
}
public struct ServiceCommand: Codable {
    public var command: String
    public var id: UUID?
    public init(_ command: String, id: UUID? = nil) { self.command = command; self.id = id }
}
/// User-level service. HID callbacks/state transitions are serial on the main
/// queue; slow app/script calls run on a bounded worker queue.
public final class StudioService {
    public var onMessage: ((ServiceMessage) -> Void)?
    public let engine: LayerEngine
    private let configURL: URL
    private let executor = StudioActionExecutor()
    private var source: ReportSource?
    private let decoder = DeviceEventDecoder()
    private var connected = false
    private var paused = false
    private var calibrating = false
    private var contextTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var holdTimer: Timer?
    private var contextBusy = false
    private var lastContextError: String?
    private var reportedUnmappedButtons = Set<Int>()
    private let queryQueue = DispatchQueue(label: "dialstudio.context")
    public init(config: StudioConfiguration, url: URL) {
        engine = LayerEngine(config); configURL = url
        engine.onAction = { [weak self] invocation in
            self?.emit(ServiceMessage("action", text: "\(invocation.profile.name) / \(invocation.layer.name) → \(invocation.binding.name)"))
            self?.executor.execute(invocation)
        }
        engine.onChange = { [weak self] in self?.sendState() }
        executor.onResult = { [weak self] message, success in
            DispatchQueue.main.async { self?.emit(ServiceMessage(success ? "result" : "error", text: message)) }
        }
        executor.onMIDI = { [weak self] bytes in
            DispatchQueue.main.async { self?.emit(ServiceMessage("midi", text: bytes.map { String(format: "%02X", $0) }.joined(separator: " "))) }
        }
        executor.onStateAction = { [weak self] action, invocation, isCurrent in
            let ok = DispatchQueue.main.sync { () -> Bool in
                guard isCurrent(), let self, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == invocation.context.bundleID,
                      self.engine.context == invocation.context else { return false }
                if action.type == .overlayHold && !self.engine.isPressActive(invocation.pressID, control: invocation.binding.control) { return true }
                return self.engine.applyStateAction(action, control: invocation.binding.control, pressID: invocation.pressID, sourceLayerID: invocation.layer.id)
            }
            if !ok { throw ConfigError("対象が変わったか、切り替え先が使用できません") }
        }
    }
    public func start() {
        connectSource()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.executor.cancelPending(); self.engine.cancelHeld(); self.refreshContext()
        }
        contextTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.refreshContext() }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }; self.engine.advance(modifiers: Self.modifiers())
        }
        refreshContext(); emit(ServiceMessage("ready", text: L("サービス起動 · 設定 v2"))); sendState()
    }
    public func stop() {
        contextTimer?.invalidate(); holdTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
        source?.stop(); source = nil; executor.cancelPending(); engine.cancelHeld(); connected = false
    }
    public func command(_ command: ServiceCommand) {
        switch command.command {
        case "reload":
            do {
                let config = try StudioConfiguration.load(from: configURL)
                let changedMode = config.mode != engine.configuration.mode
                reportedUnmappedButtons.removeAll()
                executor.cancelPending(); engine.reload(config)
                if changedMode { connectSource() }
                emit(ServiceMessage("saved", text: L("設定を反映しました"))); sendState()
            } catch { emit(ServiceMessage("error", text: LF("設定を反映できません: %@", String(describing: error)))) }
        case "pause": paused = true; source?.stop(); source = nil; engine.cancelHeld(); executor.cancelPending(); connected = false; sendState()
        case "resume": paused = false; connectSource(); sendState()
        case "layer": if let id = command.id { engine.selectLayer(id) }
        case "pin":
            if let id = command.id, !engine.configuration.profiles.contains(where: { $0.id == id && $0.enabled }) {
                emit(ServiceMessage("error", text: L("指定されたプロファイルがないか無効です。設定を保存して反映してください。"))); break
            }
            engine.pinnedProfileID = command.id; engine.updateContext(engine.context); sendState()
        case "state": sendState()
        case "calibrate": calibrating = true; engine.cancelHeld(); executor.cancelPending()
        case "endCalibration": calibrating = false; engine.cancelHeld(); decoder.reset()
        default: break
        }
    }
    private func connectSource() {
        source?.stop(); source = nil; decoder.reset(); engine.cancelHeld(); connected = false
        guard !paused else { return }
        let mode = engine.configuration.mode
        if mode == .preview { sendState(); return }
        let new: ReportSource = mode.usesHelper ? SocketReader(path: StudioConfiguration.socketPath, expectedVendor: mode == .exclusiveVendor) : HIDReader(vendor: true)
        source = new
        new.onLog = { [weak self] in self?.emit(ServiceMessage("device", text: L($0))) }
        new.onConnectionChange = { [weak self] value in
            self?.connected = value
            if !value { self?.engine.cancelHeld(); self?.decoder.reset(); self?.executor.cancelPending() }
            self?.sendState()
        }
        new.onReport = { [weak self] report in self?.receive(report) }
        new.start()
    }
    private func receive(_ report: RawReport) {
        guard !paused else { return }
        if case .button(let number, let isDown) = VendorProtocol.decode(report) {
            var message = ServiceMessage("calibration"); message.vendorButton = number; message.vendorDown = isDown; emit(message)
            if isDown && !calibrating && engine.configuration.vendorLayout[String(number)] == nil && reportedUnmappedButtons.insert(number).inserted {
                emit(ServiceMessage("device", text: LF("ボタン %d は受信しましたが、位置が未校正です。設定の「ボタンの校正」で対応付けてください。", number)))
            }
        }
        guard !calibrating else { return }
        for event in decoder.decode(report, layout: engine.configuration.vendorLayout) {
            var message = ServiceMessage("input"); message.controlEvent = event; emit(message)
            // Fail closed when the frontmost app changed before the context refresh.
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != engine.context.bundleID {
                refreshContext(); engine.cancelHeld(); continue
            }
            engine.handle(event, modifiers: Self.modifiers())
        }
    }
    private func refreshContext() {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        var context = AppContext(bundleID: bundleID, appName: app?.localizedName ?? "")
        if bundleID != "com.google.Chrome" {
            if engine.context.bundleID == bundleID { context.title = engine.context.title }
            applyContext(context)
            guard let pid = app?.processIdentifier, AXIsProcessTrusted(), !contextBusy else { return }
            contextBusy = true
            queryQueue.async { [weak self] in
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.4)
                var window: CFTypeRef?, title = ""
                if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                    let focused = unsafeBitCast(window, to: AXUIElement.self)
                    AXUIElementSetMessagingTimeout(focused, 0.4)
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &value) == .success { title = value as? String ?? "" }
                }
                DispatchQueue.main.async {
                    guard let self else { return }; self.contextBusy = false
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.refreshContext(); return }
                    var resolved = context; resolved.title = title
                    self.applyContext(resolved)
                }
            }
            return
        }
        guard !contextBusy else { return }
        let processID = app?.processIdentifier
        contextBusy = true
        queryQueue.async { [weak self] in
            let result = Result { try Chrome.tabInfo() }
            DispatchQueue.main.async {
                guard let self else { return }; self.contextBusy = false
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { self.refreshContext(); return }
                var resolved = context
                switch result {
                case .success(let tab): resolved.title = tab.title; resolved.url = tab.url; self.lastContextError = nil
                case .failure(let error):
                    let text = String(describing: error)
                    if self.lastContextError != text { self.lastContextError = text; self.emit(ServiceMessage("error", text: text)) }
                }
                self.applyContext(resolved)
            }
        }
    }
    private func applyContext(_ context: AppContext) {
        if context != engine.context {
            executor.cancelPending(); engine.updateContext(context); sendState()
            if context.bundleID == "com.google.Chrome" { executor.prepareChrome() }
        }
    }
    private func sendState() {
        var message = ServiceMessage("state", text: paused ? L("一時停止") : engine.configuration.mode.title)
        message.connected = connected; message.profileID = engine.profileID; message.layerID = engine.layer?.id
        message.profileName = engine.profile?.name; message.layerName = engine.layer?.name; message.context = engine.context
        message.activeOverlayIDs = engine.activeOverlays.map(\.id)
        message.profilePinned = engine.pinnedProfileID != nil
        emit(message)
    }
    private func emit(_ message: ServiceMessage) { onMessage?(message) }
    public static func modifiers() -> Set<KeyModifier> {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return Set([(KeyModifier.command, CGEventFlags.maskCommand), (.option, .maskAlternate), (.shift, .maskShift), (.control, .maskControl)].compactMap { flags.contains($0.1) ? $0.0 : nil })
    }
}
