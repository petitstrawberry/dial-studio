import Foundation

/// Privileged component only owns HID and forwards reports. It never reads
/// profiles or executes actions. A client connection is a lease on the device.
public final class HIDServer {
    public var onLog: ((String) -> Void)?
    private let owner: uid_t
    private let path: String
    private let vendor: Bool
    private let raw: Bool
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var reader: HIDReader?
    private var session = UUID()
    private var parentTimer: Timer?
    public init(owner: uid_t, vendor: Bool, raw: Bool = false) {
        self.owner = owner; self.vendor = vendor; self.raw = raw
        path = "/var/run/ulanzid-\(owner).sock"
    }
    public func start(parent: pid_t? = nil) throws {
        guard geteuid() == 0, owner > 0 else { throw ConfigError("HIDヘルパーは sudo で起動し、接続ユーザーのUIDを指定してください") }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == owner else { throw ConfigError("既存ソケットの所有者または種類が不正です") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            var a = try UnixSocket.address(path)
            let active = UnixSocket.withAddress(&a) { Darwin.connect(probe, $0, $1) } == 0
            close(probe)
            guard !active else { throw ConfigError("HIDヘルパーは既に起動しています") }
            guard unlink(path) == 0 else { throw ConfigError("古いソケットを削除できません") }
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ConfigError("socket failed") }
        var address = try UnixSocket.address(path)
        let oldMask = umask(0o077)
        let bound = UnixSocket.withAddress(&address) { Darwin.bind(listener, $0, $1) }
        umask(oldMask)
        guard bound == 0 else { close(listener); listener = -1; throw ConfigError("bind failed") }
        guard chown(path, owner, 0) == 0, chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { stop(); throw ConfigError("socket setup failed") }
        let listeningFD = listener
        Thread { [weak self] in
            while true {
                let s = accept(listeningFD, nil, nil)
                if s < 0 { return }
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(s, &uid, &gid) == 0, uid == self?.owner else { close(s); continue }
                DispatchQueue.main.async { self?.attach(s) }
            }
        }.start()
        if let parent {
            parentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                if kill(parent, 0) != 0 { self?.stop(); exit(0) }
            }
        }
        onLog?("listening on " + path + " — waiting for a client")
    }
    private func attach(_ s: Int32) {
        // A second client cannot displace the active service.
        guard client == -1 else { close(s); return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        client = s; session = UUID(); let lease = session
        send(HIDWireMessage(vendorMode: vendor))
        let reader = HIDReader(seize: true, vendor: vendor)
        self.reader = reader
        reader.onLog = { [weak self] text in self?.onLog?(text); self?.send(HIDWireMessage(log: text)) }
        reader.onConnectionChange = { [weak self] in self?.send(HIDWireMessage(connected: $0)) }
        reader.onReport = { [weak self] report in
            if self?.raw == true { self?.onLog?("raw \(report.reportID): \(report.bytes)") }
            self?.send(HIDWireMessage(reportID: report.reportID, bytes: report.bytes))
        }
        reader.start()
        // EOF/error revokes the lease even when the dial is idle.
        Thread { [weak self] in
            var byte: UInt8 = 0
            while read(s, &byte, 1) > 0 {}
            DispatchQueue.main.async {
                guard let self, self.session == lease else { return }
                self.detach(); close(s)
            }
        }.start()
    }
    private func send(_ message: HIDWireMessage) {
        guard client >= 0, var data = try? JSONEncoder().encode(message) else { return }
        data.append(10)
        let s = client
        let okay = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(s, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }; offset += n
            }
            return true
        }
        if !okay { shutdown(s, SHUT_RDWR) }
    }
    private func detach() {
        reader?.onConnectionChange = nil; reader?.onLog = nil; reader?.onReport = nil
        reader?.stop(); reader = nil
        if client >= 0 { shutdown(client, SHUT_RDWR); client = -1 }
        onLog?("client disconnected — dial released")
    }
    public func stop() {
        parentTimer?.invalidate(); parentTimer = nil
        detach()
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1; unlink(path) }
    }
}
