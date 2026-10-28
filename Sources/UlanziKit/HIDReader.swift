import Foundation
import IOKit.hid
import IOKit.hidsystem

public struct RawReport: Sendable {
    public let reportID: UInt32
    public let bytes: [UInt8]
    public let timestamp: TimeInterval

    public init(reportID: UInt32, bytes: [UInt8], timestamp: TimeInterval) {
        self.reportID = reportID
        self.bytes = bytes
        self.timestamp = timestamp
    }
}

public struct DeviceInfo: Sendable {
    public let name: String
    public let manufacturer: String
    public let vendorID: Int
    public let productID: Int
    public let transport: String
    public let primaryUsagePage: Int
    public let primaryUsage: Int
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let reportDescriptor: Data?
}

/// IOHID lifecycle is confined to the main run loop. Vendor mode is confirmed by
/// a valid 0xFB response, never merely by successfully opening the device.
public final class HIDReader: ReportSource {
    public static let vendorID = 0xFFF1
    public static let productID = 0x0082
    public var onReport: ((RawReport) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public var onLog: ((String) -> Void)?
    private let seize: Bool
    private let vendor: Bool
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var openedAt: TimeInterval = 0
    private var lastResponse: TimeInterval = 0
    private var confirmed = false
    private var running = false
    private var failure: IOReturn?
    private var retryAfter: TimeInterval = 0
    private var lastFailureLog: TimeInterval = 0
    private let outputQueue = DispatchQueue(label: "dialstudio.hid.output", qos: .userInitiated)
    private var outputPending = false
    private var closingDevice = false
    private var deviceGeneration = 0
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    public init(seize: Bool = false, vendor: Bool = false) { self.seize = seize; self.vendor = vendor }
    deinit { buffer.deallocate() }
    public func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        connect()
        guard running else { return }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    public func stop() {
        precondition(Thread.isMainThread)
        running = false; timer?.invalidate(); timer = nil
        disconnect()
    }
    private func tick() {
        guard running else { return }
        if device == nil {
            if ProcessInfo.processInfo.systemUptime >= retryAfter { connect() }
            return
        }
        if vendor {
            let now = ProcessInfo.processInfo.systemUptime
            if now - (confirmed ? lastResponse : openedAt) > 5 {
                retry("ベンダー応答を確認できません。入力を解放し、再接続を試みます。")
                return
            }
            sendKeepAlive()
        }
    }
    private func connect() {
        guard running, device == nil, !closingDevice else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
        _ = IOHIDManagerOpen(manager, 0)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let target = devices.first else {
            IOHIDManagerClose(manager, 0); return
        }
        IOHIDManagerClose(manager, 0)
        let result = IOHIDDeviceOpen(target, seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : 0)
        guard result == kIOReturnSuccess else {
            if failure != result {
                var message = "HID open failed: " + String(format: "0x%08X", result)
                if result == kIOReturnNotPermitted {
                    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                    let detail = access == kIOHIDAccessTypeGranted ? "入力監視は許可済み" : (access == kIOHIDAccessTypeDenied ? "入力監視が拒否されています" : "入力監視の許可が未確認です")
                    message += LF("（%@。Dial Studioの設定で入力監視の権限を確認してください。rootの場合もmacOSの権限が必要です）", L(detail))
                }
                onLog?(message)
            }
            failure = result; return
        }
        self.manager = manager; self.device = target; failure = nil
        openedAt = ProcessInfo.processInfo.systemUptime; confirmed = false
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(target, buffer, 4096, { context, result, _, _, id, data, count in
            guard let context, result == kIOReturnSuccess, count > 0, count <= 4096 else { return }
            let reader = Unmanaged<HIDReader>.fromOpaque(context).takeUnretainedValue()
            let report = RawReport(reportID: id, bytes: Array(UnsafeBufferPointer(start: data, count: count)), timestamp: Date().timeIntervalSince1970)
            if VendorProtocol.decode(report) != nil {
                reader.lastResponse = ProcessInfo.processInfo.systemUptime
                if !reader.confirmed { reader.confirmed = true; reader.onLog?("ベンダーモード応答を確認"); reader.onConnectionChange?(true) }
            }
            // Do not trigger stock actions during the vendor handshake.
            if !reader.vendor || (reader.confirmed && VendorProtocol.decode(report) != nil) { reader.onReport?(report) }
        }, ctx)
        IOHIDDeviceRegisterRemovalCallback(target, { ctx, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDReader>.fromOpaque(ctx).takeUnretainedValue().disconnect()
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(target, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if vendor { onLog?("ベンダーモード応答を待っています…"); sendKeepAlive() }
        else { confirmed = true; onConnectionChange?(true); onLog?(seize ? "標準HIDを排他接続" : "標準HIDを観測中（OSにも届きます）") }
    }
    private func sendKeepAlive() {
        guard let device, !outputPending else { return }
        outputPending = true
        let generation = deviceGeneration
        let output = VendorProtocol.output
        outputQueue.async { [weak self] in
            let rc = output.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0xFB, $0.baseAddress!, $0.count) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.deviceGeneration == generation else { return }
                self.outputPending = false
                if rc != kIOReturnSuccess { self.retry("ベンダー出力失敗: " + String(format: "0x%08X", rc) + "。再接続を試みます。") }
            }
        }
    }
    private func retry(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastFailureLog == 0 || now - lastFailureLog >= 30 { onLog?(message); lastFailureLog = now }
        retryAfter = now + 3
        disconnect()
    }
    private func disconnect() {
        deviceGeneration += 1
        outputPending = false
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            closingDevice = true
            outputQueue.async { [weak self] in
                IOHIDDeviceClose(device, 0)
                DispatchQueue.main.async { [weak self] in self?.closingDevice = false }
            }
        }
        device = nil; manager = nil; confirmed = false; onConnectionChange?(false)
    }
    public static func find() -> DeviceInfo? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        for device in devices {
            let vendor = property(device, kIOHIDVendorIDKey, Int.self) ?? -1
            let product = property(device, kIOHIDProductIDKey, Int.self) ?? -1
            let name = property(device, kIOHIDProductKey, String.self) ?? ""
            guard (vendor == vendorID && product == productID) || name.lowercased().contains("ulanzi") else {
                continue
            }
            return DeviceInfo(
                name: name,
                manufacturer: property(device, kIOHIDManufacturerKey, String.self) ?? "?",
                vendorID: vendor,
                productID: product,
                transport: property(device, kIOHIDTransportKey, String.self) ?? "?",
                primaryUsagePage: property(device, kIOHIDPrimaryUsagePageKey, Int.self) ?? -1,
                primaryUsage: property(device, kIOHIDPrimaryUsageKey, Int.self) ?? -1,
                maxInputReportSize: property(device, kIOHIDMaxInputReportSizeKey, Int.self) ?? -1,
                maxOutputReportSize: property(device, kIOHIDMaxOutputReportSizeKey, Int.self) ?? -1,
                reportDescriptor: IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
            )
        }
        return nil
    }

    private static func property<T>(_ device: IOHIDDevice, _ key: String, _ type: T.Type) -> T? {
        IOHIDDeviceGetProperty(device, key as CFString) as? T
    }
}
