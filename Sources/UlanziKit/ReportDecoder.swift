import Foundation

/// Standard/offline reports. Vendor-mode events are decoded separately in VendorProtocol.
public enum DialInput: Equatable {
    /// Dial rotation. Positive is clockwise.
    case rotate(delta: Int)
    /// Consumer usage (volume, mute, transport) with press/release.
    case consumer(usage: UInt16, down: Bool)
    /// Keyboard keycode with the modifier byte that accompanied it.
    case key(keycode: UInt8, down: Bool, modifiers: UInt8)
    /// Mouse report. Both axes are relative.
    case mouse(buttons: UInt8, dx: Int, dy: Int, wheel: Int)
    /// Unparsed vendor report.
    case vendor(reportID: UInt32, bytes: [UInt8])
}

public enum ConsumerUsage {
    public static let volumeUp: UInt16 = 0xE9
    public static let volumeDown: UInt16 = 0xEA
    public static let mute: UInt16 = 0xE2
    public static let playPause: UInt16 = 0xCD
    public static let previousTrack: UInt16 = 0xB6
    public static let nextTrack: UInt16 = 0xB5

    public static func name(_ usage: UInt16) -> String {
        switch usage {
        case volumeUp: return "volumeUp"
        case volumeDown: return "volumeDown"
        case mute: return "mute"
        case playPause: return "playPause"
        case previousTrack: return "previousTrack"
        case nextTrack: return "nextTrack"
        default: return String(format: "usage(0x%04X)", usage)
        }
    }
}

public enum KeyboardKey {
    public static let c: UInt8 = 0x06
    public static let v: UInt8 = 0x19
    public static let y: UInt8 = 0x1C
    public static let z: UInt8 = 0x1D
    public static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")

    public static func name(_ code: UInt8) -> String {
        if code >= 0x04, code <= 0x1D {
            return String(letters[Int(code) - 4]).uppercased()
        }
        return String(format: "key(0x%02X)", code)
    }
}

/// Turns raw HID reports into DialInput values.
///
/// Report layout comes from the device's own HID descriptor:
///   id 1: keyboard  [modifiers][reserved][6 keycodes]
///   id 2: consumer  [usageLo][usageHi]
///   id 3: mouse     [buttons][dx][dy][wheel]
///   id 0xFC / 0xFB: vendor, 64 bytes
public final class ReportDecoder {
    public private(set) var previousKeys: Set<UInt8> = []
    public private(set) var previousModifiers: UInt8 = 0
    public private(set) var previousConsumer: UInt16 = 0
    public private(set) var previousButtons: UInt8 = 0

    public init() {}

    public func decode(_ report: RawReport) -> [DialInput] {
        let payload = normalized(report)
        switch report.reportID {
        case 1:
            return decodeKeyboard(payload)
        case 2:
            return decodeConsumer(payload)
        case 3:
            return decodeMouse(payload)
        case 0xFC, 0xFB:
            return [.vendor(reportID: report.reportID, bytes: payload)]
        default:
            return []
        }
    }

    /// Some transports hand over the report ID as the first payload byte.
    /// The descriptor sizes are fixed, so the length tells us which shape we got.
    private func normalized(_ report: RawReport) -> [UInt8] {
        // Mouse carries buttons, X, Y, wheel and AC Pan, so five bytes.
        let expected: [UInt32: Int] = [1: 8, 2: 2, 3: 5, 0xFC: 64, 0xFB: 64]
        guard let size = expected[report.reportID],
              report.bytes.count == size + 1,
              report.bytes[0] == UInt8(truncatingIfNeeded: report.reportID) else {
            return report.bytes
        }
        return Array(report.bytes.dropFirst())
    }

    private func decodeKeyboard(_ bytes: [UInt8]) -> [DialInput] {
        guard bytes.count >= 8 else { return [] }
        let modifiers = bytes[0]
        let keys = Set(bytes[2..<8].filter { $0 != 0 })
        let pressed = keys.subtracting(previousKeys)
        let released = previousKeys.subtracting(keys)
        previousKeys = keys
        previousModifiers = modifiers
        var inputs: [DialInput] = []
        for key in pressed.sorted() { inputs.append(.key(keycode: key, down: true, modifiers: modifiers)) }
        for key in released.sorted() { inputs.append(.key(keycode: key, down: false, modifiers: modifiers)) }
        return inputs
    }

    private func decodeConsumer(_ bytes: [UInt8]) -> [DialInput] {
        guard bytes.count >= 2 else { return [] }
        let usage = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard usage != previousConsumer else { return [] }
        var inputs: [DialInput] = []
        if previousConsumer != 0 {
            inputs.append(.consumer(usage: previousConsumer, down: false))
        }
        if usage != 0 {
            inputs.append(.consumer(usage: usage, down: true))
        }
        previousConsumer = usage
        return inputs
    }

    private func decodeMouse(_ bytes: [UInt8]) -> [DialInput] {
        guard bytes.count >= 5 else { return [] }
        let buttons = bytes[0]
        let dx = Int(Int8(bitPattern: bytes[1]))
        let dy = Int(Int8(bitPattern: bytes[2]))
        let wheel = Int(Int8(bitPattern: bytes[3]))
        guard buttons != previousButtons || dx != 0 || dy != 0 || wheel != 0 else { return [] }
        previousButtons = buttons
        return [.mouse(buttons: buttons, dx: dx, dy: dy, wheel: wheel)]
    }
}
