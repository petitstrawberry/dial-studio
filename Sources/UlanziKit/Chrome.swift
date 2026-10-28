import AppKit
import Foundation

public struct ChromeTab: Sendable {
    public let title: String
    public let url: String
    public let windowID: Int
    public let tabID: Int
    public var isYouTube: Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }
}
public enum Chrome {
    public static func isRunning() -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").count > 0 }
    public static func tabInfo() throws -> ChromeTab {
        guard isRunning() else { throw ConfigError("Chrome が起動していません") }
        let source = """
        tell application "Google Chrome"
            if (count of windows) is 0 then error "Chrome のウィンドウがありません"
            set w to front window
            set t to active tab of w
            return (id of w as text) & linefeed & (id of t as text) & linefeed & (URL of t) & linefeed & (title of t)
        end tell
        """
        let text = try ProcessRunner.checked("/usr/bin/osascript", ["-e", source], timeout: 2)
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 4, let w = Int(parts[0]), let t = Int(parts[1]) else { throw ConfigError("Chrome のタブ情報を解析できません") }
        return ChromeTab(title: parts.dropFirst(3).joined(separator: "\n"), url: parts[2], windowID: w, tabID: t)
    }
    public static func executeJavaScript(_ script: String, tab: ChromeTab? = nil) throws -> String {
        let target = try tab ?? tabInfo()
        let source = """
        tell application "Google Chrome"
            set w to window id \(target.windowID)
            set t to tab id \(target.tabID) of w
            if (URL of t) is not \(ProcessRunner.appleLiteral(target.url)) then error "操作対象のタブが移動しました"
            execute t javascript \(ProcessRunner.appleLiteral(script))
        end tell
        """
        return try ProcessRunner.checked("/usr/bin/osascript", ["-e", source])
    }
    /// Check the active tab and execute in the same AppleScript invocation.
    public static func executeInActiveTab(_ script: String, expectedURL: String, run: ((String) throws -> String)? = nil) throws -> String {
        guard isRunning() else { throw ConfigError("Chrome が起動していません") }
        let source = """
        tell application "Google Chrome"
            if (count of windows) is 0 then error "Chrome のウィンドウがありません"
            set t to active tab of front window
            if (URL of t) is not \(ProcessRunner.appleLiteral(expectedURL)) then error "操作対象のタブが移動しました"
            execute t javascript \(ProcessRunner.appleLiteral(script))
        end tell
        """
        if let run { return try run(source) }
        return try ProcessRunner.checked("/usr/bin/osascript", ["-e", source])
    }
    public static func videoState() throws -> String {
        try executeJavaScript("JSON.stringify((()=>{const v=document.querySelector('video');return v?{currentTime:v.currentTime,duration:v.duration,paused:v.paused,rate:v.playbackRate}:null})())")
    }
}
