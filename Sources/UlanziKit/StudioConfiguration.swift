import Foundation

public enum Control: String, Codable, CaseIterable, Identifiable {
    case dial, knob, topLeft, topMiddle, topRight, leftTop, leftBottom, rightTop, rightBottom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dial: return L("ノブ回転")
        case .knob: return L("ノブ押下")
        case .topLeft: return L("上段 左")
        case .topMiddle: return L("上段 中央")
        case .topRight: return L("上段 右")
        case .leftTop: return L("左 上")
        case .leftBottom: return L("左 下")
        case .rightTop: return L("右 上")
        case .rightBottom: return L("右 下")
        }
    }
    public static var buttons: [Control] { allCases.filter { $0 != .dial } }
}
public enum GestureKind: String, Codable, CaseIterable, Identifiable {
    case press, release, tap, hold, holdRelease, clockwise, counterclockwise, pressedClockwise, pressedCounterclockwise
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .press: return L("押した時")
        case .release: return L("離した時")
        case .tap: return L("短く押す")
        case .hold: return L("長押し成立時")
        case .holdRelease: return L("長押し後に離した時")
        case .clockwise: return L("右へ回す")
        case .counterclockwise: return L("左へ回す")
        case .pressedClockwise: return L("押しながら右へ回す")
        case .pressedCounterclockwise: return L("押しながら左へ回す")
        }
    }
    public var isRotation: Bool { [.clockwise, .counterclockwise, .pressedClockwise, .pressedCounterclockwise].contains(self) }
    public var isCounterclockwise: Bool { self == .counterclockwise || self == .pressedCounterclockwise }

}
public enum KeyModifier: String, Codable, CaseIterable, Identifiable {
    case command, option, shift, control
    public var id: String { rawValue }
    public var title: String {
        switch self { case .command: return "⌘"; case .option: return "⌥"; case .shift: return "⇧"; case .control: return "⌃" }
    }
}
public enum ActionType: String, Codable, CaseIterable, Identifiable {
    case none, block, switchLayer, cycleLayer, previousPage, overlayHold, overlayToggle, switchProfile, cycleProfile, automaticProfile, shortcut, scroll, media, midi, shell, appleScript, browserScript, plugin
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return L("何もしない")
        case .block: return L("操作を無効にする")
        case .switchLayer: return L("ページを選ぶ")
        case .cycleLayer: return L("次のページ")
        case .previousPage: return L("前のページ")
        case .overlayHold: return L("押している間レイヤーを重ねる")
        case .overlayToggle: return L("レイヤーを重ねる／解除")
        case .switchProfile: return L("プロファイルを選ぶ")
        case .cycleProfile: return L("次のプロファイルへ")
        case .automaticProfile: return L("自動切り替えに戻す")
        case .shortcut: return L("キーボードショートカット")
        case .scroll: return L("スクロール")
        case .media: return L("システムメディア")
        case .midi: return "Mackie Control"
        case .shell: return L("シェルスクリプト")
        case .appleScript: return "AppleScript"
        case .browserScript: return L("ブラウザ JavaScript")
        case .plugin: return L("プラグイン")
        }
    }
    public var isLayer: Bool { [.switchLayer, .cycleLayer, .previousPage, .overlayHold, .overlayToggle].contains(self) }
    public var isProfile: Bool { [.switchProfile, .cycleProfile, .automaticProfile].contains(self) }
}
public struct StudioAction: Codable, Equatable {
    public var type: ActionType = .none
    public var value: String = ""
    public var amount: Double = 1
    public var targetLayer: UUID?
    public var targetProfile: UUID?
    public var keyCommand: String?
    public var mcuIndex: Int?
    public var pluginSettings: [String: String]?
    public init(_ type: ActionType = .none, value: String = "", amount: Double = 1, layer: UUID? = nil, profile: UUID? = nil) {
        self.type = type; self.value = value; self.amount = amount; self.targetLayer = layer; self.targetProfile = profile
    }
    public var summary: String {
        if type == .none { return "未設定" }
        if type.isLayer { return type.title }
        if type.isProfile { return type.title }
        return value.isEmpty ? type.title : "\(type.title) · \(value.prefix(40))"
    }
}
public struct ActionStep: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var delayMilliseconds: Int
    public var action: StudioAction
    public init(action: StudioAction, delayMilliseconds: Int = 0) {
        self.action = action; self.delayMilliseconds = delayMilliseconds
    }
}
public struct StudioBinding: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var name = "新しい割り当て"
    public var control: Control = .dial
    public var gesture: GestureKind = .clockwise
    public var held: Set<Control> = []
    public var modifiers: Set<KeyModifier> = []
    public var action = StudioAction()
    /// Additional actions, each with a delay before it is executed.
    public var steps: [ActionStep]?
    public var enabled = true
    public init(name: String = L("新しい割り当て"), control: Control = .dial, gesture: GestureKind = .clockwise,
                held: Set<Control> = [], modifiers: Set<KeyModifier> = [], action: StudioAction = StudioAction()) {
        self.name = name; self.control = control; self.gesture = gesture; self.held = held; self.modifiers = modifiers; self.action = action
    }
    public var triggerLabel: String {
        let prefix = held.sorted { $0.rawValue < $1.rawValue }.map(\.title) + modifiers.sorted { $0.rawValue < $1.rawValue }.map(\.title)
        return (prefix + [control.title, gesture.title]).joined(separator: " ＋ ")
    }
}
public struct StudioLayer: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var symbol: String
    public var bindings: [StudioBinding]
    public init(name: String = L("新しいレイヤー"), symbol: String = "square.stack", bindings: [StudioBinding] = []) {
        self.name = name; self.symbol = symbol; self.bindings = bindings
    }
}
public struct StudioPage: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    /// Ordered bottom to top; the first layer is always active.
    public var layers: [StudioLayer]
    public init(name: String = L("新しいページ"), layers: [StudioLayer] = [StudioLayer(name: L("基本"))]) {
        self.name = name; self.layers = layers
    }
}
public struct StudioProfile: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var bundleID: String
    public var iconData: Data?
    public var host: String
    public var titleContains: String?
    public var pages: [StudioPage]
    public var enabled = true
    public init(name: String = L("新しいプロファイル"), bundleID: String = "", host: String = "", pages: [StudioPage] = [StudioPage(name: L("基本"))]) {
        self.name = name; self.bundleID = bundleID; self.host = host; self.pages = pages
    }
}
public enum InputMode: String, Codable, CaseIterable, Identifiable {
    case preview, vendor, exclusiveVendor, exclusiveStock
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .preview: return L("プレビュー（実機を接続しない）")
        case .vendor: return L("ベンダーモード")
        case .exclusiveVendor: return L("ベンダーモード · root ヘルパー")
        case .exclusiveStock: return L("標準入力 · root ヘルパー")
        }
    }
    public var usesHelper: Bool { self == .exclusiveVendor || self == .exclusiveStock }
}
public enum HUDPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .topLeft: return L("左上")
        case .topCenter: return L("上中央")
        case .topRight: return L("右上")
        case .bottomLeft: return L("左下")
        case .bottomCenter: return L("下中央")
        case .bottomRight: return L("右下")
        }
    }
}
public struct StudioConfiguration: Codable, Equatable {
    public var version = 3
    public var profiles: [StudioProfile]
    public var mode: InputMode = .preview
    public var holdMilliseconds = 450
    public var showHUD = true
    public var hudPosition: HUDPosition = .bottomCenter
    public var menuBarOnly = false
    /// Vendor button numbers are calibrated explicitly instead of assuming a physical layout.
    public var vendorLayout: [String: Control] = [:]
    public init(profiles: [StudioProfile] = []) { self.profiles = profiles }
    private enum CodingKeys: String, CodingKey { case version, profiles, mode, holdMilliseconds, showHUD, hudPosition, menuBarOnly, vendorLayout }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        profiles = try c.decode([StudioProfile].self, forKey: .profiles)
        mode = try c.decode(InputMode.self, forKey: .mode)
        holdMilliseconds = try c.decode(Int.self, forKey: .holdMilliseconds)
        showHUD = try c.decode(Bool.self, forKey: .showHUD)
        hudPosition = try c.decodeIfPresent(HUDPosition.self, forKey: .hudPosition) ?? .bottomCenter
        menuBarOnly = try c.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? false
        vendorLayout = try c.decode([String: Control].self, forKey: .vendorLayout)

    }
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dial Studio", isDirectory: true)
    }
    public static var fileURL: URL { directory.appendingPathComponent("configuration-v3.json") }
    public static var socketPath: String { "/var/run/ulanzid-\(getuid()).sock" }
    public func validate() throws {
        guard version == 3 else { throw ConfigError(LF("未対応の設定バージョン: %d", version)) }
        guard (100...3000).contains(holdMilliseconds) else { throw ConfigError("長押しの判定は100〜3000msです") }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ConfigError("プロファイルIDが重複しています") }
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !profile.pages.isEmpty else { throw ConfigError("プロファイルには名前と1つ以上のレイヤーが必要です") }
            guard profile.host.isEmpty || (!profile.host.contains("/") && !profile.bundleID.isEmpty) else { throw ConfigError("サイト条件はホスト名で指定し、アプリも指定してください") }
            let layerIDs = profile.pages.flatMap(\.layers).map(\.id)
            guard Set(layerIDs).count == layerIDs.count, Set(profile.pages.map(\.id)).count == profile.pages.count else { throw ConfigError("ページまたはレイヤーIDが重複しています") }
            for page in profile.pages {
                guard !page.name.isEmpty, !page.layers.isEmpty else { throw ConfigError("ページには名前と1つ以上のレイヤーが必要です") }
                for layer in page.layers {
                guard !layer.name.isEmpty else { throw ConfigError("レイヤー名が空です") }
                guard Set(layer.bindings.map(\.id)).count == layer.bindings.count else { throw ConfigError("割り当てIDが重複しています") }
                var triggers = Set<String>()
                for b in layer.bindings where b.enabled {
                    let key = b.triggerLabel
                    guard triggers.insert(key).inserted else { throw ConfigError(LF("%@ / %@: 同じ入力条件が重複しています（%@）", profile.name, layer.name, key)) }
                    guard (b.control == .dial) == b.gesture.isRotation, !b.held.contains(.dial), !b.held.contains(b.control) else { throw ConfigError(LF("%@: 入力条件が矛盾しています", b.name)) }
                    let amountLimit: Double = b.action.type == .midi && b.action.value == "fader" ? 16383 : 10000
                    guard b.action.amount.isFinite && abs(b.action.amount) <= amountLimit else { throw ConfigError(LF("%@: 操作量が範囲外です", b.name)) }
                    if b.action.type == .switchLayer {
                        guard let target = b.action.targetLayer, profile.pages.contains(where: { $0.id == target }) else { throw ConfigError(LF("%@: 切り替え先レイヤーがありません", b.name)) }
                    }
                    if [.overlayHold, .overlayToggle].contains(b.action.type) {
                        guard let target = b.action.targetLayer, page.layers.contains(where: { $0.id == target }) else { throw ConfigError(L("切り替え先のレイヤーがありません")) }
                    }
                    if b.action.type == .overlayHold && ![.press, .hold].contains(b.gesture) { throw ConfigError(L("継続アクションは「押した時」か「長押し成立時」に割り当ててください")) }
                    if b.action.type == .switchProfile {
                        guard let target = b.action.targetProfile, profiles.contains(where: { $0.id == target }) else { throw ConfigError(LF("%@: 切り替え先プロファイルがありません", b.name)) }
                    }
                    if b.action.type == .shortcut { _ = try InputMonitor.KeySpec.parse(b.action.value) }
                    if b.action.type == .midi && b.action.value == "recordEnd" { _ = try InputMonitor.KeySpec.parse(b.action.keyCommand ?? "keypadmultiply") }
                    if b.action.type == .midi && ["control", "controlDown", "controlUp"].contains(b.action.value), !(0...112).contains(b.action.mcuIndex ?? 0x5e) { throw ConfigError("Mackie ボタン番号が範囲外です") }
                    if b.action.type == .midi && b.action.value == "vpot", !(0...7).contains(b.action.mcuIndex ?? 0) { throw ConfigError("V-Pot番号が範囲外です") }
                    if b.action.type == .midi && b.action.value == "fader" {
                        guard (0...8).contains(b.action.mcuIndex ?? 0), b.action.amount.rounded() == b.action.amount, (0...16383).contains(b.action.amount) else { throw ConfigError("フェーダー位置は0〜16383の整数で指定してください") }
                    }
                    if [.shell, .appleScript, .browserScript].contains(b.action.type) && b.action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ConfigError(LF("%@: スクリプトが空です", b.name)) }
                    if let steps = b.steps {
                        guard steps.isEmpty || b.action.type != .none else { throw ConfigError(LF("%@: 最初のアクションがありません", b.name)) }
                        guard steps.isEmpty || b.action.type != .block else { throw ConfigError(L("無効化は連続アクションに追加できません")) }
                        guard steps.count <= 32, Set(steps.map(\.id)).count == steps.count else { throw ConfigError(LF("%@: アクション数またはIDが不正です", b.name)) }
                        for step in steps {
                            guard (0...60000).contains(step.delayMilliseconds) else { throw ConfigError(LF("%@: 待ち時間は0〜60000ミリ秒です", b.name)) }
                            let a = step.action
                            guard a.type != .none, a.type != .block else { throw ConfigError(LF("%@: 無効なアクションがあります", b.name)) }
                            guard a.amount.isFinite && abs(a.amount) <= (a.type == .midi && a.value == "fader" ? 16383 : 10000) else { throw ConfigError(LF("%@: 操作量が範囲外です", b.name)) }
                            if a.type == .switchLayer {
                                guard let target = a.targetLayer, profile.pages.contains(where: { $0.id == target }) else { throw ConfigError(LF("%@: 切り替え先レイヤーがありません", b.name)) }
                            }
                            if [.overlayHold, .overlayToggle].contains(a.type), !(a.targetLayer.map { target in page.layers.contains { $0.id == target } } ?? false) { throw ConfigError(L("切り替え先のレイヤーがありません")) }
                            if a.type == .overlayHold && ![.press, .hold].contains(b.gesture) { throw ConfigError(L("継続アクションは「押した時」か「長押し成立時」に割り当ててください")) }
                            if a.type == .switchProfile, !(a.targetProfile.map { target in profiles.contains { $0.id == target } } ?? false) { throw ConfigError(LF("%@: 切り替え先プロファイルがありません", b.name)) }
                            if a.type == .shortcut { _ = try InputMonitor.KeySpec.parse(a.value) }
                            if a.type == .midi && a.value == "recordEnd" { _ = try InputMonitor.KeySpec.parse(a.keyCommand ?? "keypadmultiply") }
                            if a.type == .midi && ["control", "controlDown", "controlUp"].contains(a.value), !(0...112).contains(a.mcuIndex ?? 0x5e) { throw ConfigError("Mackie ボタン番号が範囲外です") }
                            if a.type == .midi && a.value == "vpot", !(0...7).contains(a.mcuIndex ?? 0) { throw ConfigError("V-Pot番号が範囲外です") }
                            if a.type == .midi && a.value == "fader", (!(0...8).contains(a.mcuIndex ?? 0) || a.amount.rounded() != a.amount || !(0...16383).contains(a.amount)) { throw ConfigError("フェーダー位置は0〜16383の整数で指定してください") }
                            if [.shell, .appleScript, .browserScript].contains(a.type) && a.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ConfigError(LF("%@: スクリプトが空です", b.name)) }
                        }
                    }
                }
                }
            }
        }
        let calibrated = vendorLayout.values
        guard vendorLayout.keys.allSatisfy({ Int($0).map { (1...7).contains($0) } ?? false }),
              calibrated.allSatisfy({ $0 != .dial && $0 != .knob }), Set(calibrated).count == calibrated.count else { throw ConfigError("ボタン校正が重複または範囲外です") }
    }
    public func save(to url: URL = Self.fileURL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL = fileURL) throws -> Self {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)); try config.validate(); return config
    }
}
public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = L(description) }
}

public extension StudioConfiguration {
    static var starter: Self {
        func pair(_ name: String, _ type: ActionType, _ value: String, _ amount: Double, held: Set<Control> = []) -> [StudioBinding] {
            [StudioBinding(name: name + " ＋", gesture: .clockwise, held: held, action: StudioAction(type, value: value, amount: amount)),
             StudioBinding(name: name + " −", gesture: .counterclockwise, held: held, action: StudioAction(type, value: value, amount: -amount))]
        }
        var playback = StudioLayer(name: L("再生"), symbol: "play.circle", bindings: pair(L("シーク 5秒"), .media, "seek", 5))
        let fine = StudioLayer(name: L("微調整"), symbol: "scope", bindings: pair(L("シーク 0.5秒"), .media, "seek", 0.5))
        var transportPage = StudioPage(name: L("移動"))
        var zoomPage = StudioPage(name: L("編集"))
        playback.bindings += [
            StudioBinding(name: L("再生 / 一時停止"), control: .topMiddle, gesture: .tap, action: StudioAction(.media, value: "playPause")),
            StudioBinding(name: L("押している間は微調整"), control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: fine.id))]
        var transport = StudioLayer(name: L("移動"), symbol: "waveform", bindings: pair(L("ジョグ"), .midi, "jog", 1))
        var zoom = StudioLayer(name: L("編集"), symbol: "arrow.up.left.and.arrow.down.right")
        zoom.bindings = [StudioBinding(name: L("横ズーム拡大"), gesture: .clockwise, action: StudioAction(.shortcut, value: "cmd+right")), StudioBinding(name: L("横ズーム縮小"), gesture: .counterclockwise, action: StudioAction(.shortcut, value: "cmd+left"))]
        transport.bindings += [
            StudioBinding(name: L("再生"), control: .topMiddle, gesture: .tap, action: StudioAction(.midi, value: "play")),
            StudioBinding(name: L("停止"), control: .topLeft, gesture: .tap, action: StudioAction(.midi, value: "stop")),
            StudioBinding(name: L("編集モード"), control: .topRight, gesture: .tap, action: StudioAction(.switchLayer, layer: zoomPage.id))]
        zoom.bindings.append(StudioBinding(name: L("移動モード"), control: .topLeft, gesture: .tap, action: StudioAction(.switchLayer, layer: transportPage.id)))
        transportPage.layers = [transport]; zoomPage.layers = [zoom]
        return Self(profiles: [StudioProfile(name: "Chrome", bundleID: "com.google.Chrome", pages: [StudioPage(name: L("再生"), layers: [playback, fine])]), StudioProfile(name: "Logic Pro", bundleID: "com.apple.logic10", pages: [transportPage, zoomPage]), StudioProfile(name: L("その他のアプリ"))])
    }
}
