import CoreMIDI
import Foundation

/// Mackie Control transport. Encoders/jog use relative CC; pitch bend is for faders.
public final class MCU {
    // Logic maps Mackie Control's USER SWITCH A to Play/Stop.
    public enum Button: UInt8 { case record = 0x5F, play = 0x5E, stop = 0x5D, playStop = 0x66, rewind = 0x5B, forward = 0x5C, loop = 0x56 }
    public static let controls: [(id: Int, name: String)] = {
        var result: [(Int, String)] = []
        for (offset, name) in [(0, "録音待機"), (8, "ソロ"), (16, "ミュート"), (24, "選択"), (32, "V-Pot 押下")] {
            for i in 0..<8 { result.append((offset + i, "\(L(name)) \(i + 1)")) }
        }
        let names = ["Track", "Send", "Pan / Surround", "Plug-in", "EQ", "Instrument", "Bank 左", "Bank 右", "Channel 左", "Channel 右", "Flip", "Global", "Name / Value", "SMPTE / Beats", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "MIDI Tracks", "Inputs", "Audio Tracks", "Audio Instruments", "Aux", "Busses", "Outputs", "User", "Shift", "Option", "Control", "Alt", "Read / Off", "Write", "Trim", "Touch", "Latch", "Group", "Save", "Undo", "Cancel", "Enter", "Marker", "Nudge", "Cycle", "Drop", "Replace", "Click", "Solo", "巻き戻し", "早送り", "停止", "再生", "録音", "上", "下", "左", "右", "Zoom", "Scrub", "User Switch A", "User Switch B"]
        result += names.enumerated().map { ($0.offset + 0x28, L($0.element)) }
        for i in 0..<8 { result.append((0x68 + i, LF("フェーダー %d タッチ", i + 1))) }
        result.append((0x70, L("マスターフェーダー タッチ")))
        return result
    }()
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private let heldLock = NSLock()
    private var heldControls = Set<UInt8>()
    public var onFeedback: (([UInt8]) -> Void)?
    public init?(name: String = "Dial Studio MCU") {
        guard MIDIClientCreateWithBlock(name as CFString, &client, { _ in }) == noErr else { return nil }
        guard MIDISourceCreate(client, name as CFString, &source) == noErr else { MIDIClientDispose(client); client = 0; return nil }
        let result = MIDIDestinationCreateWithBlock(client, name as CFString, &destination) { [weak self] packets, _ in
            let packet = packets.pointee.packet
            for _ in 0..<packets.pointee.numPackets {
                let bytes = withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) }
                self?.onFeedback?(bytes)
                // Current feedback surface only logs the first packet. No guessed track state.
                break
            }
        }
        guard result == noErr else { MIDIEndpointDispose(source); MIDIClientDispose(client); source = 0; client = 0; return nil }
    }
    deinit { if source != 0 { MIDIEndpointDispose(source) }; if destination != 0 { MIDIEndpointDispose(destination) }; if client != 0 { MIDIClientDispose(client) } }
    public static func relativeCC(_ controller: UInt8, ticks: Int) -> [UInt8] {
        let magnitude = Int(min(63, ticks.magnitude))
        return [0xB0, controller, UInt8(magnitude | (ticks < 0 ? 0x40 : 0))]
    }
    public func press(_ button: Button) { send([0x90, button.rawValue, 0x7F]); send([0x90, button.rawValue, 0]) }
    public func jog(_ ticks: Int) { if ticks != 0 { send(Self.relativeCC(0x3C, ticks: ticks)) } }
    public func note(_ number: UInt8, velocity: UInt8) { send([0x90, min(127, number), min(127, velocity)]) }
    public func control(_ number: UInt8) { note(number, velocity: 127); note(number, velocity: 0) }
    public func controlDown(_ number: UInt8) {
        heldLock.lock(); heldControls.insert(number); note(number, velocity: 127); heldLock.unlock()
    }
    public func controlUp(_ number: UInt8) {
        heldLock.lock(); heldControls.remove(number); note(number, velocity: 0); heldLock.unlock()
    }
    public func releaseHeldControls() {
        heldLock.lock()
        for number in heldControls { note(number, velocity: 0) }
        heldControls.removeAll()
        heldLock.unlock()
    }
    public static func faderMessages(_ index: Int, value: Int) -> [[UInt8]] {
        let channel = max(0, min(8, index)), position = max(0, min(16383, value))
        let touch = UInt8(0x68 + channel)
        return [[0x90, touch, 127], [0xE0 | UInt8(channel), UInt8(position & 0x7f), UInt8((position >> 7) & 0x7f)], [0x90, touch, 0]]
    }
    public func fader(_ index: Int, value: Int) { for message in Self.faderMessages(index, value: value) { send(message) } }
    public func vpot(_ index: Int, ticks: Int) { if ticks != 0 { send(Self.relativeCC(UInt8(0x10 + max(0, min(7, index))), ticks: ticks)) } }
    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, bytes.count <= 3 else { return }
        var list = MIDIPacketList()
        let first = MIDIPacketListInit(&list)
        _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, first, 0, $0.count, $0.baseAddress!) }
        MIDIReceived(source, &list)
    }
}
