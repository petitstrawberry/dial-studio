import AudioToolbox
import CoreAudio
import Foundation

/// Adjusts the current output device without synthesizing keyboard events.
public enum SystemAudio {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func outputDevice() throws -> AudioDeviceID {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw ConfigError(LF("システムの音声出力先を取得できません (%d)", status)) }
        return device
    }
    private static func ensureWritable(_ device: AudioDeviceID, _ property: inout AudioObjectPropertyAddress) throws {
        var writable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &property), AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue else {
            throw ConfigError("現在の音声出力先はこの音量操作に対応していません")
        }
    }
    public static func adjustVolume(steps: Int) throws {
        guard (-32...32).contains(steps), steps != 0 else { throw ConfigError("システム音量の操作量は -32〜-1 または 1〜32 の整数にしてください") }
        let device = try outputDevice()
        var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        try ensureWritable(device, &property)
        var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        var status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value)
        guard status == noErr else { throw ConfigError(LF("出力音量を読み取れません (%d)", status)) }
        value = min(1, max(0, value + Float32(steps) / 16))
        status = AudioObjectSetPropertyData(device, &property, 0, nil, size, &value)
        guard status == noErr else { throw ConfigError(LF("出力音量を変更できません (%d)", status)) }
    }
    public static func toggleMute() throws {
        let device = try outputDevice()
        var property = address(kAudioDevicePropertyMute)
        try ensureWritable(device, &property)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        var status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value)
        guard status == noErr else { throw ConfigError(LF("ミュート状態を読み取れません (%d)", status)) }
        value = value == 0 ? 1 : 0
        status = AudioObjectSetPropertyData(device, &property, 0, nil, size, &value)
        guard status == noErr else { throw ConfigError(LF("ミュート状態を変更できません (%d)", status)) }
    }
}
