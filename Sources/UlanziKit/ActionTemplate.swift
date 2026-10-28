import Foundation

public struct ActionTemplate: Identifiable {
    public let id: String
    public let title: String
    public let group: String
    public let symbol: String
    public let action: StudioAction
    public let relative: Bool
    public var payload: String { "dialstudio/action/" + id }
    public init(_ id: String, _ title: String, _ group: String, _ symbol: String, _ action: StudioAction, relative: Bool = false) {
        self.id = id; self.title = L(title); self.group = L(group); self.symbol = symbol; self.action = action; self.relative = relative
    }
    public static let groups = ["Mackie Control", "Logic", "ページ", "レイヤー", "プロファイル", "システム", "スクリプト"].map(L)
    public static let all: [Self] = [
        Self("midi.jog", "ジョグ", "Mackie Control", "dial.low", StudioAction(.midi, value: "jog"), relative: true),
        Self("midi.play", "再生", "Mackie Control", "play", StudioAction(.midi, value: "play")),
        Self("midi.stop", "停止", "Mackie Control", "stop", StudioAction(.midi, value: "stop")),
        Self("midi.playStop", "再生 / 停止", "Logic", "playpause", StudioAction(.midi, value: "playStop")),
        Self("midi.record", "録音", "Mackie Control", "record.circle", StudioAction(.midi, value: "record")),
        Self("midi.recordBegin", "録音開始", "Logic", "record.circle", StudioAction(.midi, value: "recordBegin")),
        Self("midi.recordEnd", "録音停止（再生継続）", "Logic", "record.circle", StudioAction(.midi, value: "recordEnd")),
        Self("midi.recordStop", "録音 / 停止", "Logic", "record.circle", StudioAction(.midi, value: "recordStop")),
        Self("midi.loop", "サイクル", "Mackie Control", "repeat", StudioAction(.midi, value: "loop")),
        Self("midi.rewind", "巻き戻し", "Mackie Control", "backward", StudioAction(.midi, value: "rewind")),
        Self("midi.forward", "早送り", "Mackie Control", "forward", StudioAction(.midi, value: "forward")),
        Self("midi.vpot", "V-Pot 回転", "Mackie Control", "dial.medium", StudioAction(.midi, value: "vpot"), relative: true),
        Self("midi.control", "Mackie ボタン", "Mackie Control", "button.programmable", StudioAction(.midi, value: "control")),
        Self("midi.controlDown", "Mackie ボタンを押す", "Mackie Control", "hand.point.down", StudioAction(.midi, value: "controlDown")),
        Self("midi.controlUp", "Mackie ボタンを離す", "Mackie Control", "hand.raised", StudioAction(.midi, value: "controlUp")),
        Self("midi.fader", "フェーダー位置", "Mackie Control", "slider.vertical.3", StudioAction(.midi, value: "fader", amount: 8192)),
        Self("layer.switch", "ページを選ぶ", "ページ", "rectangle.on.rectangle", StudioAction(.switchLayer)),
        Self("layer.cycle", "次のページ", "ページ", "arrow.right", StudioAction(.cycleLayer)),
        Self("page.previous", "前のページ", "ページ", "arrow.left", StudioAction(.previousPage)),
        Self("overlay.hold", "押している間レイヤーを重ねる", "レイヤー", "hand.point.up", StudioAction(.overlayHold)),
        Self("overlay.toggle", "レイヤーを重ねる／解除", "レイヤー", "square.stack.3d.up", StudioAction(.overlayToggle)),
        Self("overlay.block", "操作を無効にする", "レイヤー", "nosign", StudioAction(.block)),
        Self("profile.select", "プロファイルを選ぶ", "プロファイル", "person.crop.rectangle.stack", StudioAction(.switchProfile)),
        Self("profile.next", "次のプロファイル", "プロファイル", "arrow.triangle.2.circlepath", StudioAction(.cycleProfile)),
        Self("profile.auto", "自動切り替えに戻す", "プロファイル", "sparkles", StudioAction(.automaticProfile)),
        Self("system.shortcut", "ショートカット", "システム", "keyboard", StudioAction(.shortcut, value: "space")),
        Self("system.scroll", "スクロール", "システム", "arrow.up.arrow.down", StudioAction(.scroll), relative: true),
        Self("system.volume", "システム音量", "システム", "speaker.wave.2", StudioAction(.media, value: "volume", amount: 1), relative: true),
        Self("system.mute", "システムミュート", "システム", "speaker.slash", StudioAction(.media, value: "mute")),
        Self("system.playPause", "メディア 再生 / 一時停止", "システム", "playpause", StudioAction(.media, value: "playPause")),
        Self("system.seek", "メディア シーク", "システム", "goforward.5", StudioAction(.media, value: "seek", amount: 5), relative: true),
        Self("system.previous", "メディア 前の曲", "システム", "backward.end", StudioAction(.media, value: "previous")),
        Self("system.next", "メディア 次の曲", "システム", "forward.end", StudioAction(.media, value: "next")),
        Self("script.shell", "シェルスクリプト", "スクリプト", "terminal", StudioAction(.shell, value: "printf '%s\\n' \"$DIAL_CONTEXT_JSON\""), relative: true),
        Self("script.apple", "AppleScript", "スクリプト", "applescript", StudioAction(.appleScript, value: "return system attribute \"DIAL_CONTEXT_JSON\""), relative: true),
        Self("script.browser", "ブラウザ JavaScript", "スクリプト", "chevron.left.forwardslash.chevron.right", StudioAction(.browserScript, value: "return JSON.stringify({title: document.title, url: location.href, amount});"), relative: true)
    ]
    public static func from(payload: String) -> Self? { all.first { $0.payload == payload } }
}

public struct AssignmentChange {
    public let bindingID: UUID
    public let replaced: Bool
}
public extension StudioConfiguration {
    mutating func append(_ template: ActionTemplate, profileID: UUID, layerID: UUID, bindingID: UUID) throws {
        guard let p = profiles.firstIndex(where: { $0.id == profileID }), let page = profiles[p].pages.firstIndex(where: { $0.layers.contains(where: { $0.id == layerID }) }), let l = profiles[p].pages[page].layers.firstIndex(where: { $0.id == layerID }),
              let b = profiles[p].pages[page].layers[l].bindings.firstIndex(where: { $0.id == bindingID }) else { throw ConfigError("割り当て先がありません") }
        let binding = profiles[p].pages[page].layers[l].bindings[b]
        guard (binding.steps?.count ?? 0) < 32 else { throw ConfigError("追加できるアクションは最大33件です") }
        var action = template.action
        if action.type == .overlayHold && ![.press, .hold].contains(binding.gesture) { throw ConfigError("継続アクションは「押した時」か「長押し成立時」に追加してください") }
        if (action.type == .block && binding.action.type != .none) || binding.action.type == .block { throw ConfigError(L("無効化は連続アクションに追加できません")) }
        if template.relative && binding.gesture.isCounterclockwise { action.amount = -abs(action.amount) }
        if action.type == .switchLayer { action.targetLayer = profiles[p].pages.first { $0.id != profiles[p].pages[page].id }?.id ?? profiles[p].pages.first?.id }
        if [.overlayHold, .overlayToggle].contains(action.type) {
            guard let target = profiles[p].pages[page].layers.dropFirst().first else { throw ConfigError(L("先にレイヤーを追加してください")) }
            action.targetLayer = target.id
        }
        if action.type == .switchProfile { action.targetProfile = profiles.first { $0.id != profileID && $0.enabled }?.id ?? profileID }
        if binding.action.type == .none { profiles[p].pages[page].layers[l].bindings[b].action = action }
        else {
            if profiles[p].pages[page].layers[l].bindings[b].steps == nil { profiles[p].pages[page].layers[l].bindings[b].steps = [] }
            profiles[p].pages[page].layers[l].bindings[b].steps?.append(ActionStep(action: action))
        }
    }
    /// Drop updates only the unconditional binding for this exact physical gesture.
    /// Button chords and modifier-specific bindings are kept intact.
    mutating func assign(_ template: ActionTemplate, profileID: UUID, layerID: UUID, control: Control, gesture requested: GestureKind? = nil) throws -> AssignmentChange {
        guard let p = profiles.firstIndex(where: { $0.id == profileID }), let page = profiles[p].pages.firstIndex(where: { $0.layers.contains(where: { $0.id == layerID }) }), let l = profiles[p].pages[page].layers.firstIndex(where: { $0.id == layerID }) else { throw ConfigError("割り当て先のレイヤーがありません") }
        var action = template.action
        if action.type == .overlayHold && control == .dial { throw ConfigError("「押している間だけ」はボタンへドロップしてください") }
        let gesture: GestureKind
        if let requested {
            gesture = action.type == .overlayHold ? (requested == .hold ? .hold : .press) : requested
        } else if control == .dial {
            gesture = .clockwise
        } else {
            let candidates: [GestureKind] = action.type == .overlayHold ? [.press, .hold] : [.press, .tap, .hold, .release, .holdRelease]
            let bindings = profiles[p].pages[page].layers[l].bindings.filter { $0.control == control && $0.held.isEmpty && $0.modifiers.isEmpty }
            guard let free = candidates.first(where: { candidate in
                !bindings.contains { $0.gesture == candidate && ($0.action.type != .none || $0.steps?.isEmpty == false) }
            }) else { throw ConfigError(L("この入力の操作はすべて割り当て済みです。既存の割り当てにアクションを追加してください。")) }
            gesture = free
        }
        guard (control == .dial) == gesture.isRotation else { throw ConfigError("この入力には割り当てられません") }
        if template.relative && gesture.isCounterclockwise { action.amount = -abs(action.amount) }
        if action.type == .switchLayer {
            action.targetLayer = profiles[p].pages.first { $0.id != profiles[p].pages[page].id }?.id ?? profiles[p].pages.first?.id
        }
        if [.overlayHold, .overlayToggle].contains(action.type) {
            guard let target = profiles[p].pages[page].layers.dropFirst().first else { throw ConfigError(L("先にレイヤーを追加してください")) }
            action.targetLayer = target.id
        }
        if action.type == .switchProfile {
            let currentID = profiles[p].id
            action.targetProfile = profiles.first { $0.id != currentID && $0.enabled }?.id ?? currentID
        }
        let name = template.title + (control == .dial ? (gesture.isCounterclockwise ? " −" : " ＋") : "")
        if let i = profiles[p].pages[page].layers[l].bindings.firstIndex(where: { $0.control == control && $0.gesture == gesture && $0.held.isEmpty && $0.modifiers.isEmpty }) {
            profiles[p].pages[page].layers[l].bindings[i].name = name
            profiles[p].pages[page].layers[l].bindings[i].action = action
            profiles[p].pages[page].layers[l].bindings[i].steps = nil
            profiles[p].pages[page].layers[l].bindings[i].enabled = true
            return AssignmentChange(bindingID: profiles[p].pages[page].layers[l].bindings[i].id, replaced: true)
        }
        let binding = StudioBinding(name: name, control: control, gesture: gesture, action: action)
        profiles[p].pages[page].layers[l].bindings.append(binding)
        return AssignmentChange(bindingID: binding.id, replaced: false)
    }
}
