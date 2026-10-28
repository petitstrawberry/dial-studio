import AppKit
import Foundation
import IOKit.hidsystem

/// Output only. No event tap or time-correlated suppression.
public enum InputMonitor {
    private static let keyPostingLock = NSLock()
    static func mediaEvent(_ code: Int, pressed: Bool) -> CGEvent? {
        let state = pressed ? 0xA : 0xB
        return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)?.cgEvent
    }
    public static func mediaKey(_ code: Int) throws {
        for pressed in [true, false] {
            guard let event = mediaEvent(code, pressed: pressed) else {
                throw ConfigError("メディアキーイベントを作成できません")
            }
            event.post(tap: .cghidEventTap)
        }
    }
    public enum KeySpec {
        public static let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "space": 49, " ": 49, "return": 36, "tab": 48,
            "escape": 53, "delete": 51, "left": 123, "right": 124,
            "down": 125, "up": 126, "keypadmultiply": 67, "f1": 122, "f2": 120, "f3": 99,
            "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
            "f18": 79, "f19": 80, "f20": 90,
        ]

        public static func parse(_ spec: String) throws -> (CGKeyCode, CGEventFlags) {
            var flags: CGEventFlags = []
            let parts = spec.lowercased().split(separator: "+").map(String.init)
            guard let key = parts.last else { throw KeyError.badSpec(spec) }
            for modifier in parts.dropLast() {
                switch modifier {
                case "cmd", "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "ctrl", "control": flags.insert(.maskControl)
                case "alt", "opt", "option": flags.insert(.maskAlternate)
                default: throw KeyError.badSpec(spec)
                }
            }
            guard let code = table[key] else { throw KeyError.unknownKey(key) }
            return (code, flags)
        }

        /// Use the same physical key mapping for recording and playback.
        public static func recorded(keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
            guard let key = table.keys.sorted().first(where: { $0 != " " && table[$0] == keyCode }) else { return nil }
            var parts: [String] = []
            if flags.contains(.maskCommand) { parts.append("cmd") }
            if flags.contains(.maskAlternate) { parts.append("option") }
            if flags.contains(.maskControl) { parts.append("ctrl") }
            if flags.contains(.maskShift) { parts.append("shift") }
            parts.append(key)
            return parts.joined(separator: "+")
        }

        public enum KeyError: Error, CustomStringConvertible {
            case badSpec(String)
            case unknownKey(String)

            public var description: String {
                switch self {
                case .badSpec(let spec): return "bad key spec: " + spec
                case .unknownKey(let key): return "unknown key: " + key
                }
            }
        }
    }

    public static func tapKey(_ spec: String) throws {
        let (code, flags) = try KeySpec.parse(spec)
        keyPostingLock.lock()
        defer { keyPostingLock.unlock() }
        let previousFlags = CGEventSource.flagsState(.hidSystemState)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ConfigError("ショートカットのキーイベントを作成できません")
        }
        down.flags = flags
        // Posting to the HID tap updates the system modifier state even with a
        // private source. Restore the state that existed before the shortcut.
        up.flags = previousFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    public static func scroll(lines: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }
}
