import Foundation

public struct ProcessResult { public let output: String; public let status: Int32 }
public enum ProcessRunner {
    /// Bound both execution time and captured output, including commands that spawn children.
    public static func run(_ executable: String, _ args: [String], environment: [String: String] = [:], timeout: TimeInterval = 4) throws -> ProcessResult {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ConfigError("pipe failed") }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { close(readFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        // A separate process group lets timeout terminate ordinary descendants too.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + args).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let envp = env.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
            posix_spawn(&pid, executable, &actions, &attributes, av.baseAddress!, ev.baseAddress!)
        }}
        close(writeFD)
        guard result == 0 else { throw ConfigError(LF("実行できません: %@", String(cString: strerror(result)))) }
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(); var chunk = [UInt8](repeating: 0, count: 4096); var status: Int32 = 0
        func drain() {
            // Bounded per iteration so continuous output cannot prevent timeout.
            for _ in 0..<32 {
                let count = read(readFD, &chunk, chunk.count)
                if count <= 0 { break }
                if data.count < 65536 { data.append(contentsOf: chunk.prefix(min(count, 65536 - data.count))) }
            }
        }
        while true {
            drain()
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { drain(); break }
            if waited < 0 && errno != EINTR { throw ConfigError("プロセスの終了状態を取得できません") }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(-pid, SIGTERM)
                // Always kill the original group as children may outlive the shell.
                Thread.sleep(forTimeInterval: 0.1); kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw ConfigError(LF("処理がタイムアウトしました（%@秒）", String(timeout)))
            }
            var pollFD = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            _ = poll(&pollFD, 1, 15)
            if pollFD.revents & Int16(POLLHUP) != 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProcessResult(output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), status: code)
    }
    public static func checked(_ executable: String, _ args: [String], environment: [String: String] = [:], timeout: TimeInterval = 4) throws -> String {
        let result = try run(executable, args, environment: environment, timeout: timeout)
        guard result.status == 0 else { throw ConfigError(result.output.isEmpty ? "処理失敗（\(result.status)）" : result.output) }
        return result.output
    }
    public static func appleLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    public static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
