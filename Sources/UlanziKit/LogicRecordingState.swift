import AppKit
import ApplicationServices

enum LogicRecordingState {
    static func recordButton(recording: Bool) -> MCU.Button { recording ? .stop : .record }

    static func read(pid: pid_t) throws -> Bool {
        guard AXIsProcessTrusted() else { throw ConfigError("録音状態の取得にはアクセシビリティ許可が必要です") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            throw ConfigError("Logic のプロジェクトウインドウを取得できません")
        }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var pending = [window]
        var index = 0
        while index < pending.count && index < 3000 {
            let element = pending[index]; index += 1
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
               let role = role as? String, role == kAXCheckBoxRole as String {
                var title: CFTypeRef?, description: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
                let labels: [String] = [title as? String, description as? String].compactMap { $0 }
                if labels.contains("録音") || labels.contains("Record") {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                          let number = value as? NSNumber, number.intValue == 0 || number.intValue == 1 else {
                        throw ConfigError("Logic の録音状態を取得できません")
                    }
                    return number.boolValue
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] { pending.append(contentsOf: children) }
        }
        throw ConfigError("Logic の録音ボタンが見つかりません。プロジェクトのコントロールバーを表示してください")
    }
}
