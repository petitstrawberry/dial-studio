import Foundation

/// A single serial caller owns this worker. The child isolates slow or hung
/// Apple Events so a timeout can terminate it without wedging the service.
final class ChromeScriptWorker {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private let executable: String
    private let arguments: [String]
    init(executable: String = CommandLine.arguments[0], arguments: [String] = ["chrome-worker"]) {
        self.executable = executable; self.arguments = arguments
    }
    deinit { stop() }

    func execute(_ source: String, timeout: TimeInterval = 4) throws -> String {
        guard source.utf8.count <= 65536 else { throw ConfigError("Chrome のスクリプトが長すぎます") }
        do {
            if process?.isRunning != true { stop(); try start() }
            guard let input, let output else { throw ConfigError("Chrome 操作プロセスを起動できません") }
            var request = try JSONEncoder().encode(source); request.append(10)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let inFD = input.fileHandleForWriting.fileDescriptor
            let outFD = output.fileHandleForReading.fileDescriptor
            var offset = 0
            while offset < request.count {
                try wait(fd: inFD, events: Int16(POLLOUT), deadline: deadline)
                let n = request.withUnsafeBytes { Darwin.write(inFD, $0.baseAddress!.advanced(by: offset), request.count - offset) }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw ConfigError("Chrome 操作プロセスへの送信に失敗しました") }
                offset += n
            }
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    let response = try JSONDecoder().decode([String: String].self, from: line)
                    if let error = response["error"] { throw ConfigError(error) }
                    guard let result = response["result"] else { throw ConfigError("Chrome 操作の応答が不正です") }
                    return result
                }
                try wait(fd: outFD, events: Int16(POLLIN), deadline: deadline)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(outFD, &bytes, bytes.count)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw ConfigError("Chrome 操作プロセスが終了しました") }
                buffer.append(contentsOf: bytes.prefix(n))
                guard buffer.count <= 262144 else { throw ConfigError("Chrome 操作の応答が長すぎます") }
            }
        } catch { stop(); throw error }
    }

    private func start() throws {
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(stdout.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        process = p; input = stdin; output = stdout
    }
    private func wait(fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ConfigError("Chrome 操作がタイムアウトしました") }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let rc = poll(&p, 1, Int32(min(remaining * 1000, 1000)))
            if rc < 0 && errno == EINTR { continue }
            if rc < 0 { throw ConfigError("Chrome 操作プロセスの通信に失敗しました") }
            if p.revents & events != 0 { return }
            if p.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw ConfigError("Chrome 操作プロセスが終了しました") }
        }
    }
    private func stop() {
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        process = nil; input = nil; output = nil; buffer.removeAll()
    }
}
