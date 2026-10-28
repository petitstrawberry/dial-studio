import Foundation

/// homebrew issue #2 -> ftl/hamdial/doc/protocol.md and event.go.
/// Button indices are protocol IDs, not assumed physical positions.
public enum VendorProtocol {
    public static let token: [UInt8] = [0x38, 0x90, 0xC4, 0x99, 0xA3, 0x60, 0xAA, 0xAD]
    public static let keepAlive: [UInt8] = [0x24, 0x56, 0x9E, 0xF2, 0x28, 0xE1, 0x45, 0xA1]
    public static let response = "21f45eb71c3587ab"
    public static var output: [UInt8] { [0xFB] + keepAlive + token + [UInt8](repeating: 0, count: 48) }
    public static let codes: [(String, String)] = [
        ("8e8f5e16ec67281e", "028db3660224d0c7"), ("22d73cfa751ffbc7", "96f6b51a60f4ff67"),
        ("983ae16d833a42a4", "abc5377eda49be8b"), ("3d2e482ac73d9006", "446e3a0ed925a0a2"),
        ("e6ae57c883933971", "dc24a2910177965f"), ("2e426bb625bb36dd", "250846c7e37615f9"),
        ("ff79b4421864a3f1", "73d198d9c446dfb2")]
    public enum Event: Equatable { case keepAlive, button(Int, Bool), knob(Bool), rotation(Int), pressedRotation(Int) }
    public static func decode(_ report: RawReport) -> Event? {
        guard report.reportID == 0xFB else { return nil }
        let bytes: [UInt8]
        if report.bytes.count == 65 && report.bytes.first == 0xFB { bytes = Array(report.bytes.dropFirst()) }
        else if report.bytes.count == 64 { bytes = report.bytes } else { return nil }
        guard Array(bytes[8..<16]) == token else { return nil }
        let code = bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
        if code == response { return .keepAlive }
        if code == "3edd5f9e876af42c" { return .rotation(1) }
        if code == "b06be536dbe92e9d" { return .rotation(-1) }
        if code == "719b15f1c58517fe" { return .pressedRotation(1) }
        if code == "014b14c8d0069800" { return .pressedRotation(-1) }
        if code == "838cc9ca145c72ed" { return .knob(true) }
        if code == "85138e54a3497900" { return .knob(false) }
        for (i, pair) in codes.enumerated() {
            if code == pair.0 { return .button(i + 1, true) }
            if code == pair.1 { return .button(i + 1, false) }
        }
        return nil
    }
}
public final class DeviceEventDecoder {
    private var standard = ReportDecoder()
    public init() {}
    public func reset() { standard = ReportDecoder() }
    public func decode(_ report: RawReport, layout: [String: Control]) -> [ControlEvent] {
        if let event = VendorProtocol.decode(report) {
            switch event {
            case .keepAlive: return []
            case .rotation(let d): return [ControlEvent(.dial, .rotate, delta: d)]
            case .pressedRotation(let d): return [ControlEvent(.dial, .rotate, delta: d, pressedRotation: true)]
            case .knob(let down): return [ControlEvent(.knob, down ? .down : .up)]
            case .button(let n, let down):
                guard let control = layout[String(n)] else { return [] }
                return [ControlEvent(control, down ? .down : .up)]
            }
        }
        return standard.decode(report).flatMap { input -> [ControlEvent] in
            switch input {
            case .consumer(let usage, let down):
                if usage == ConsumerUsage.volumeUp || usage == ConsumerUsage.volumeDown {
                    return down ? [ControlEvent(.dial, .rotate, delta: usage == ConsumerUsage.volumeUp ? 1 : -1)] : []
                }
                let map: [UInt16: Control] = [ConsumerUsage.mute: .knob, ConsumerUsage.playPause: .topMiddle, ConsumerUsage.previousTrack: .topLeft, ConsumerUsage.nextTrack: .topRight]
                guard let control = map[usage] else { return [] }
                return [ControlEvent(control, down ? .down : .up)]
            case .key(let key, let down, _):
                let map: [UInt8: Control] = [KeyboardKey.v: .leftTop, KeyboardKey.c: .leftBottom, KeyboardKey.y: .rightTop, KeyboardKey.z: .rightBottom]
                guard let control = map[key] else { return [] }
                return [ControlEvent(control, down ? .down : .up)]
            default: return []
            }
        }
    }
}
