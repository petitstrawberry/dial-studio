import Foundation
import AppKit
import UlanziKit

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
}
let url = URL(fileURLWithPath: option("--config") ?? StudioConfiguration.fileURL.path)
setvbuf(stdout, nil, _IOLBF, 0)
var signals: [DispatchSourceSignal] = []
func cleanup(_ block: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { block(); exit(0) }; source.resume(); signals.append(source)
    }
}
do {
    switch args.first ?? "help" {
    case "chrome-worker":
        // NSAppleScript initializes AppKit; without an explicit policy this
        // helper is registered as another foreground Dial Studio application.
        NSApplication.shared.setActivationPolicy(.prohibited)
        while let line = readLine() {
            guard let data = line.data(using: .utf8), let source = try? JSONDecoder().decode(String.self, from: data) else { continue }
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message: [String: String]
            if let error { message = ["error": (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript の実行に失敗しました"] }
            else if let result { message = ["result": result.stringValue ?? ""] }
            else { message = ["error": "AppleScript を作成できません"] }
            if let encoded = try? JSONEncoder().encode(message), let line = String(data: encoded, encoding: .utf8) { print(line) }
        }
    case "serve", "run":
        // NSWorkspace and CoreMIDI can initialize AppKit even for this CLI.
        // Set the policy before starting the service so it never registers as
        // another foreground instance of the containing application.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let service = StudioService(config: try StudioConfiguration.load(from: url), url: url)
        service.onMessage = { message in
            if let data = try? JSONEncoder().encode(message), let line = String(data: data, encoding: .utf8) { print(line) }
        }
        cleanup { service.stop() }; service.start()
        Thread {
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let command = try? JSONDecoder().decode(ServiceCommand.self, from: data) else { continue }
                DispatchQueue.main.async {
                    if command.command == "quit" { service.stop(); exit(0) }
                    service.command(command)
                }
            }
            DispatchQueue.main.async { service.stop(); exit(0) }
        }.start()
        RunLoop.main.run()
    case "hidd":
        let owner = uid_t(option("--owner") ?? ProcessInfo.processInfo.environment["SUDO_UID"] ?? "0") ?? 0
        let server = HIDServer(owner: owner, vendor: args.contains("--vendor"), raw: args.contains("--raw"))
        server.onLog = { print($0) }
        try server.start(parent: option("--parent").flatMap(Int32.init))
        cleanup { server.stop() }; RunLoop.main.run()
    case "watch":
        let source: ReportSource = args.contains("--local") || args.contains("--vendor") ? HIDReader(vendor: args.contains("--vendor")) : SocketReader(path: StudioConfiguration.socketPath)
        let decoder = ReportDecoder()
        source.onLog = { print($0) }; source.onConnectionChange = { print("connected: \($0)") }
        source.onReport = { report in
            if args.contains("--raw") { print("raw \(report.reportID): " + report.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")) }
            if let vendor = VendorProtocol.decode(report) { print(vendor) }
            else { for event in decoder.decode(report) { print(event) } }
        }
        source.start(); cleanup { source.stop() }
        if let seconds = option("--seconds").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { source.stop(); exit(0) }
        }
        RunLoop.main.run()
    case "init":
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ConfigError("既存の設定は上書きしません: \(url.path)") }
        try StudioConfiguration.starter.save(to: url); print(url.path)
    case "check":
        let config = try StudioConfiguration.load(from: url)
        print("OK: \(config.profiles.count) profiles, \(config.profiles.flatMap(\.pages).flatMap(\.layers).count) layers")
    case "list":
        if let info = HIDReader.find() { print(info) } else { print("D100H not found"); exit(1) }
    case "ble":
        let probe = BLEProbe(); probe.onLog = { print($0) }; probe.start(seconds: 12); RunLoop.main.run()
    case "chrome":
        let tab = try Chrome.tabInfo(); print("\(tab.title)\n\(tab.url)")
        if tab.isYouTube { print(try Chrome.videoState()) }
    default:
        print("""
        Dial Studio · ulanzid
          serve --config PATH        user service; NDJSON commands on stdin
          init [--config PATH]       create starter configuration
          check [--config PATH]      validate configuration
          list                       inspect connected D100H
          watch [--raw]              connect to running root helper
          watch --vendor --seconds 8 probe vendor mode without root
          sudo ulanzid hidd [--vendor] [--owner UID] [--raw]
          chrome status              inspect front Chrome tab
        GUI: open Dial Studio.app
        """)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
