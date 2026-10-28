import Foundation

enum SystemMedia {
    static func target(elapsed: Double, duration: Double?, delta: Double) throws -> Double {
        guard elapsed.isFinite, elapsed >= 0, delta.isFinite else { throw ConfigError("再生位置を取得できません") }
        let upper = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Double(Int64.max) / 1_000_000
        return max(0, min(upper, elapsed + delta))
    }

    static func seek(seconds: Double) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/MediaRemoteAdapter")
        let script = resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework").path
        guard FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: framework) else {
            throw ConfigError("シーク用の MediaRemote アダプタがありません。配布版アプリをビルドしてください")
        }
        let json = try ProcessRunner.checked("/usr/bin/perl", [script, framework, "get", "--now", "--no-artwork", "--allow-missing-title"], timeout: 3)
        guard let info = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let elapsed = info["elapsedTimeNow"] as? Double ?? info["elapsedTime"] as? Double else {
            throw ConfigError("現在再生中のメディアの位置を取得できません")
        }
        let position = try target(elapsed: elapsed, duration: info["duration"] as? Double, delta: seconds)
        let microseconds = Int64((position * 1_000_000).rounded())
        _ = try ProcessRunner.checked("/usr/bin/perl", [script, framework, "seek", String(microseconds)], timeout: 3)
    }
}
