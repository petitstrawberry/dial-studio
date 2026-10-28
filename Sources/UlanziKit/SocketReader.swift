import Foundation

public struct HIDWireMessage: Codable {
    public var connected: Bool?
    public var log: String?
    public var reportID: UInt32?
    public var bytes: [UInt8]?
    public var vendorMode: Bool?
    public init(connected: Bool? = nil, log: String? = nil, reportID: UInt32? = nil, bytes: [UInt8]? = nil, vendorMode: Bool? = nil) {
        self.connected = connected; self.log = log; self.reportID = reportID; self.bytes = bytes
        self.vendorMode = vendorMode
    }
}
public enum UnixSocket {
    public static func address(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX); a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { throw ConfigError("ソケットパスが長すぎます") }
        withUnsafeMutableBytes(of: &a.sun_path) { raw in for (i, byte) in bytes.enumerated() { raw[i] = byte } }
        return a
    }
    public static func withAddress<T>(_ address: inout sockaddr_un, _ block: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { block($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
}
/// Only accepts a root-owned helper. Connection state comes from the device,
/// not from successful socket connection. stop() uses shutdown, avoiding fd reuse races.
public final class SocketReader: ReportSource {
    public var onReport: ((RawReport) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public var onLog: ((String) -> Void)?
    private let path: String
    private let expectedVendor: Bool?
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = true
    // These fields are accessed only on the main queue by deliver().
    private var rejectingMode = false
    private var mismatchReported = false
    public init(path: String, expectedVendor: Bool? = nil) { self.path = path; self.expectedVendor = expectedVendor }
    public func start() {
        lock.lock(); guard stopped else { lock.unlock(); return }; stopped = false; lock.unlock()
        Thread { [self] in run() }.start()
    }
    public func stop() {
        lock.lock(); stopped = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) }; lock.unlock()
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func deliver(_ msg: HIDWireMessage) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            if let mode = msg.vendorMode, let expected = self.expectedVendor {
                if mode != expected {
                    self.rejectingMode = true
                    if !self.mismatchReported {
                        self.onLog?("ヘルパーの接続方式が設定と異なります。ヘルパーを終了して再起動してください。")
                        self.mismatchReported = true
                    }
                    self.onConnectionChange?(false)
                    self.lock.lock(); if self.fd >= 0 { shutdown(self.fd, SHUT_RDWR) }; self.lock.unlock()
                    return
                }
                self.rejectingMode = false; self.mismatchReported = false
            }
            guard !self.rejectingMode else { return }
            if let connected = msg.connected { self.onConnectionChange?(connected) }
            if let log = msg.log { self.onLog?(log) }
            if let id = msg.reportID, let bytes = msg.bytes, bytes.count <= 4096 {
                self.onReport?(RawReport(reportID: id, bytes: bytes, timestamp: Date().timeIntervalSince1970))
            }
        }
    }
    private func run() {
        var waiting = false
        while !isStopped {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0, var addr = try? UnixSocket.address(path) else { return }
            let rc = UnixSocket.withAddress(&addr) { Darwin.connect(s, $0, $1) }
            var uid: uid_t = 0; var gid: gid_t = 0
            if rc != 0 || getpeereid(s, &uid, &gid) != 0 || uid != 0 {
                close(s)
                if !waiting { deliver(HIDWireMessage(log: "排他ヘルパーの接続を待っています")); waiting = true }
                Thread.sleep(forTimeInterval: 0.5); continue
            }
            lock.lock()
            if stopped { close(s); lock.unlock(); return }
            fd = s; lock.unlock(); waiting = false
            var pending = Data(); var bytes = [UInt8](repeating: 0, count: 8192)
            while !isStopped {
                let n = read(s, &bytes, bytes.count)
                if n <= 0 { break }
                pending.append(contentsOf: bytes.prefix(n))
                while let end = pending.firstIndex(of: 10) {
                    let line = pending[..<end]; pending.removeSubrange(...end)
                    if let msg = try? JSONDecoder().decode(HIDWireMessage.self, from: Data(line)) { deliver(msg) }
                }
                if pending.count > 32768 { break }
            }
            lock.lock(); fd = -1; close(s); lock.unlock()
            deliver(HIDWireMessage(connected: false))
            if !isStopped { Thread.sleep(forTimeInterval: 0.5) }
        }
    }
}
