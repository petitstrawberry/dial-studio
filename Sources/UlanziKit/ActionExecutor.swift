import Foundation
import AppKit
import IOKit.hidsystem

public final class StudioActionExecutor {
    public var onResult: ((String, Bool) -> Void)?
    public var onMIDI: (([UInt8]) -> Void)?
    public var onStateAction: ((StudioAction, ActionInvocation, () -> Bool) throws -> Void)?
    private let queue = DispatchQueue(label: "dialstudio.actions", qos: .userInitiated)
    // Each sequence keeps its own order without blocking unrelated input while waiting.
    private let sequenceQueue = DispatchQueue(label: "dialstudio.action-sequences", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0
    private final class SeekBatch {
        let invocation: ActionInvocation
        var amount: Double
        init(_ invocation: ActionInvocation) { self.invocation = invocation; amount = invocation.binding.action.amount }
    }
    private var seekTail: SeekBatch?
    private final class RotationBatch {
        let invocation: ActionInvocation
        var count = 1
        init(_ invocation: ActionInvocation) { self.invocation = invocation }
    }
    private var rotationTail: RotationBatch?
    private var midi: MCU?
    private let chromeWorker = ChromeScriptWorker()
    private var chromeWarmupScheduled = false
    private var performOverride: ((ActionInvocation) throws -> String)?
    public init() {
        midi = MCU()
        midi?.onFeedback = { [weak self] bytes in self?.onMIDI?(bytes) }
    }
    init(perform: @escaping (ActionInvocation) throws -> String) {
        performOverride = perform
    }
    public func cancelPending() { lock.lock(); generation += 1; seekTail = nil; rotationTail = nil; lock.unlock(); midi?.releaseHeldControls() }
    public func prepareChrome() {
        lock.lock()
        guard !chromeWarmupScheduled else { lock.unlock(); return }
        chromeWarmupScheduled = true; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.chromeWorker.execute("tell application \"Google Chrome\" to get id of front window")
            } catch {
                self.lock.lock(); self.chromeWarmupScheduled = false; self.lock.unlock()
                self.onResult?("Chrome の準備に失敗しました: \(error)", false)
            }
        }
    }
    public func execute(_ invocation: ActionInvocation) {
        let hasSteps = invocation.binding.steps?.isEmpty == false
        guard hasSteps || (!invocation.binding.action.type.isLayer && !invocation.binding.action.type.isProfile && invocation.binding.action.type != .none) else { return }
        lock.lock()
        let action = invocation.binding.action
        let canBatch = !hasSteps && action.type == .media && action.value == "seek"
        let canBatchRotation = !hasSteps && invocation.binding.control == .dial && action.type == .shortcut
        if canBatchRotation, let tail = rotationTail, tail.count < 8,
           tail.invocation.binding.id == invocation.binding.id,
           tail.invocation.profile.id == invocation.profile.id,
           tail.invocation.layer.id == invocation.layer.id,
           tail.invocation.context == invocation.context {
            tail.count += 1; lock.unlock(); return
        }
        rotationTail = nil
        if canBatch, let tail = seekTail,
           tail.invocation.binding.id == invocation.binding.id,
           tail.invocation.profile.id == invocation.profile.id,
           tail.invocation.layer.id == invocation.layer.id,
           tail.invocation.context == invocation.context {
            tail.amount += action.amount
            lock.unlock(); return
        }
        seekTail = nil
        let limit = canBatchRotation ? 4 : (invocation.binding.control == .dial ? 12 : 64)
        guard pending < limit else { lock.unlock(); onResult?(L("入力が処理速度を超えたため、この操作を省略しました"), false); return }
        let batch = canBatch ? SeekBatch(invocation) : nil
        let rotation = canBatchRotation ? RotationBatch(invocation) : nil
        seekTail = batch
        rotationTail = rotation
        pending += 1; let token = generation; lock.unlock()
        (hasSteps ? sequenceQueue : queue).async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            self.lock.lock()
            let valid = token == self.generation
            let amount = batch?.amount
            let repetitions = rotation?.count ?? 1
            if let batch, self.seekTail === batch { self.seekTail = nil }
            if let rotation, self.rotationTail === rotation { self.rotationTail = nil }
            self.lock.unlock()
            guard valid else { return }
            do {
                var binding = invocation.binding
                if let amount { binding.action.amount = amount }
                let effective = ActionInvocation(binding: binding, profile: invocation.profile, layer: invocation.layer, context: invocation.context, pressID: invocation.pressID)
                let output: String
                if let steps = effective.binding.steps, !steps.isEmpty {
                    output = try self.performSequence(effective, steps: steps, token: token)
                } else {
                    var last = ""
                    for _ in 0..<repetitions {
                        guard self.isCurrent(token) else { break }
                        last = try self.performOverride?(effective) ?? self.perform(effective)
                    }
                    output = last
                }
                self.onResult?(output.isEmpty ? invocation.binding.name : output, true)
            } catch { self.onResult?(String(describing: error), false) }
        }
    }
    private func isCurrent(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return token == generation }
    private func performSequence(_ invocation: ActionInvocation, steps: [ActionStep], token: Int) throws -> String {
        let sequence = [ActionStep(action: invocation.binding.action)] + steps
        for (index, step) in sequence.enumerated() {
            let deadline = ProcessInfo.processInfo.systemUptime + Double(step.delayMilliseconds) / 1000
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard isCurrent(token) else { throw ConfigError("アクションの連続実行を中止しました") }
                Thread.sleep(forTimeInterval: min(0.025, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
            guard isCurrent(token) else { throw ConfigError("アクションの連続実行を中止しました") }
            var binding = invocation.binding; binding.action = step.action; binding.steps = nil
            let current = ActionInvocation(binding: binding, profile: invocation.profile, layer: invocation.layer, context: invocation.context, pressID: invocation.pressID)
            do {
                if step.action.type.isLayer || step.action.type.isProfile {
                    guard let onStateAction else { throw ConfigError("レイヤー／プロファイルを変更できません") }
                    try onStateAction(step.action, current) { self.isCurrent(token) }
                } else {
                    _ = try performOverride?(current) ?? perform(current)
                }
            } catch { throw ConfigError(LF("アクション %d で停止: %@", index + 1, String(describing: error))) }
        }
        return "\(invocation.binding.name): \(sequence.count) 件を実行"
    }
    private func perform(_ invocation: ActionInvocation) throws -> String {
        let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }
        guard front == invocation.context.bundleID else { throw ConfigError("実行前にアプリが切り替わったため中止しました") }
        let action = invocation.binding.action
        let data = try JSONEncoder().encode(invocation.context)
        let json = String(decoding: data, as: UTF8.self)
        switch action.type {
        case .shortcut:
            guard AXIsProcessTrusted() else { throw ConfigError("ショートカット送信にはアクセシビリティ許可が必要です") }
            try InputMonitor.tapKey(action.value)
        case .scroll:
            guard AXIsProcessTrusted() else { throw ConfigError("スクロール送信にはアクセシビリティ許可が必要です") }
            InputMonitor.scroll(lines: Int(action.amount))
        case .media:
            switch action.value {
            case "seek": try SystemMedia.seek(seconds: action.amount)
            case "volume":
                guard action.amount.isFinite, action.amount.rounded() == action.amount, (1...32).contains(abs(action.amount)) else { throw ConfigError("システム音量の操作量は -32〜-1 または 1〜32 の整数にしてください") }
                try SystemAudio.adjustVolume(steps: Int(action.amount))
            case "mute": try SystemAudio.toggleMute()
            case "playPause", "next", "previous":
                guard AXIsProcessTrusted() else { throw ConfigError("メディアキーの送信にはアクセシビリティ許可が必要です") }
                let key = action.value == "playPause" ? NX_KEYTYPE_PLAY : (action.value == "next" ? NX_KEYTYPE_NEXT : NX_KEYTYPE_PREVIOUS)
                try InputMonitor.mediaKey(Int(key))
            default: throw ConfigError(LF("不明なシステムメディア操作: %@", action.value))
            }
        case .browserScript:
            guard invocation.context.bundleID == "com.google.Chrome" else { throw ConfigError("操作対象が Chrome ではありません") }
            let script = "(()=>{const ctx=\(json);const amount=\(action.amount);\n\(action.value)\n})()"
            let output = try Chrome.executeInActiveTab(script, expectedURL: invocation.context.url) { try self.chromeWorker.execute($0) }
            if output.hasPrefix("ERROR:") { throw ConfigError(output) }
            return output
        case .midi:
            guard let midi else { throw ConfigError("MIDIポートを作成できませんでした") }
            switch action.value {
            case "jog": midi.jog(Int(action.amount))
            case "vpot": midi.vpot(action.mcuIndex ?? 0, ticks: Int(action.amount))
            case "control": midi.control(UInt8(action.mcuIndex ?? 0x5e))
            case "controlDown": midi.controlDown(UInt8(action.mcuIndex ?? 0x5e))
            case "controlUp": midi.controlUp(UInt8(action.mcuIndex ?? 0x5e))
            case "fader": midi.fader(action.mcuIndex ?? 0, value: Int(action.amount))
            case "play": midi.press(.play)
            case "stop": midi.press(.stop)
            case "playStop": midi.press(.playStop)
            case "record": midi.press(.record)
            case "recordStop", "recordBegin", "recordEnd":
                guard invocation.context.bundleID == "com.apple.logic10",
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
                    throw ConfigError("Logic Pro が前面にありません")
                }
                let recording = try LogicRecordingState.read(pid: app.processIdentifier)
                let current = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
                guard current == app.processIdentifier else { throw ConfigError("実行前にアプリが切り替わったため中止しました") }
                switch action.value {
                case "recordStop": midi.press(LogicRecordingState.recordButton(recording: recording))
                case "recordBegin": if !recording { midi.press(.record) }
                case "recordEnd": if recording { try InputMonitor.tapKey(action.keyCommand ?? "keypadmultiply") }
                default: break
                }
            case "rewind": midi.press(.rewind)
            case "forward": midi.press(.forward)
            case "loop": midi.press(.loop)
            default: throw ConfigError(LF("不明な MIDI 操作: %@", action.value))
            }
        case .shell:
            return try ProcessRunner.checked("/bin/zsh", ["-c", action.value], environment: ["DIAL_CONTEXT_JSON": json, "DIAL_AMOUNT": String(action.amount), "DIAL_PROFILE": invocation.profile.name, "DIAL_LAYER": invocation.layer.name], timeout: 5)
        case .appleScript:
            return try ProcessRunner.checked("/usr/bin/osascript", ["-e", action.value], environment: ["DIAL_CONTEXT_JSON": json, "DIAL_AMOUNT": String(action.amount)], timeout: 5)
        default: break
        }
        return ""
    }
}
