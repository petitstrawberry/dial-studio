import Foundation
import AppKit

/// A plugin is a directory ending in .dialplugin with a manifest and module.
public struct PluginManifest: Codable {
    public struct Field: Codable, Identifiable {
        public var id: String
        public var title: String
        public var defaultValue: String?
    }
    public struct Action: Codable, Identifiable {
        public var id: String
        public var title: String
        public var symbol: String?
        public var relative: Bool?
        public var fields: [Field]?
    }
    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var description: String?
    public var license: String?
    public var kind: String
    public var entrypoint: String
    public var actions: [Action]
}

public struct InstalledPlugin {
    public let manifest: PluginManifest
    public let directory: URL
    public let entrypoint: URL
    public func action(_ id: String) -> PluginManifest.Action? { manifest.actions.first { $0.id == id } }
}

public enum PluginRegistry {
    public static var directory: URL { StudioConfiguration.directory.appendingPathComponent("Plugins", isDirectory: true) }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }
    public static func load(_ url: URL) throws -> InstalledPlugin {
        guard url.pathExtension == "dialplugin" else { throw ConfigError("プラグインの拡張子は .dialplugin にしてください") }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
        guard validID(manifest.id), !manifest.name.isEmpty, !manifest.version.isEmpty, !manifest.actions.isEmpty,
              Set(manifest.actions.map(\.id)).count == manifest.actions.count,
              manifest.actions.allSatisfy({ validID($0.id) && !$0.title.isEmpty && Set(($0.fields ?? []).map(\.id)).count == ($0.fields ?? []).count && ($0.fields ?? []).allSatisfy { validID($0.id) && !$0.title.isEmpty } }) else {
            throw ConfigError("プラグインのIDまたはアクション定義が不正です")
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let entry = root.appendingPathComponent(manifest.entrypoint).resolvingSymlinksInPath().standardizedFileURL
        let expected = manifest.kind == "dylib" ? "dylib" : (manifest.kind == "wasm" ? "wasm" : "")
        guard !expected.isEmpty, !manifest.entrypoint.hasPrefix("/"), entry.path.hasPrefix(root.path + "/"), entry.pathExtension == expected, FileManager.default.isReadableFile(atPath: entry.path) else {
            throw ConfigError("プラグインのモジュールがないか形式が不正です")
        }
        return InstalledPlugin(manifest: manifest, directory: root, entrypoint: entry)
    }
    public static func scan(at root: URL) -> (plugins: [InstalledPlugin], errors: [String]) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return ([], []) }
        var plugins: [InstalledPlugin] = [], errors: [String] = [], ids = Set<String>()
        for url in urls.filter({ $0.pathExtension == "dialplugin" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let plugin = try load(url)
                guard ids.insert(plugin.manifest.id).inserted else { throw ConfigError("プラグインIDが重複しています") }
                plugins.append(plugin)
            } catch { errors.append("\(url.lastPathComponent): \(error)") }
        }
        return (plugins, errors)
    }
    public static func scan() -> (plugins: [InstalledPlugin], errors: [String]) {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources.appendingPathComponent("Plugins", isDirectory: true)) }
        roots.append(directory)
        var result: [InstalledPlugin] = [], errors: [String] = [], ids = Set<String>()
        for root in roots {
            let found = scan(at: root); errors += found.errors
            for plugin in found.plugins {
                if ids.insert(plugin.manifest.id).inserted { result.append(plugin) }
                else { errors.append("\(plugin.directory.lastPathComponent): " + L("プラグインIDが重複しています")) }
            }
        }
        return (result, errors)
    }
    public static func key(plugin: String, action: String) -> String { "\(plugin)/\(action)" }
    public static func resolve(_ key: String, at root: URL? = nil) -> (InstalledPlugin, PluginManifest.Action)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let plugins = root.map { scan(at: $0).plugins } ?? scan().plugins
        guard let plugin = plugins.first(where: { $0.manifest.id == String(parts[0]) }), let action = plugin.action(String(parts[1])) else { return nil }
        return (plugin, action)
    }
    public static func templates(_ plugins: [InstalledPlugin]) -> [ActionTemplate] {
        plugins.flatMap { plugin in plugin.manifest.actions.map { action in
            var value = StudioAction(.plugin, value: key(plugin: plugin.manifest.id, action: action.id))
            value.pluginSettings = Dictionary(uniqueKeysWithValues: (action.fields ?? []).map { ($0.id, $0.defaultValue ?? "") })
            return ActionTemplate("plugin." + value.value, action.title, plugin.manifest.name, action.symbol ?? "puzzlepiece.extension", value, relative: action.relative ?? false)
        } }
    }
    public static func execute(_ invocation: ActionInvocation, at root: URL? = nil, worker workerOverride: URL? = nil) throws -> String {
        let action = invocation.binding.action
        guard let (plugin, definition) = resolve(action.value, at: root) else { throw ConfigError("プラグインまたはアクションが見つかりません: \(action.value)") }
        let event = ["control": invocation.binding.control.rawValue, "gesture": invocation.binding.gesture.rawValue, "pressID": invocation.pressID?.uuidString ?? "", "bindingID": invocation.binding.id.uuidString, "profileID": invocation.profile.id.uuidString, "layerID": invocation.layer.id.uuidString]
        let request = PluginRequest(action: definition.id, context: invocation.context, event: event, settings: action.pluginSettings ?? [:], amount: action.amount, profile: invocation.profile.name, layer: invocation.layer.name)
        let data = try JSONEncoder().encode(request)
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ulanzid").path
        let worker = workerOverride?.path ?? (FileManager.default.isExecutableFile(atPath: path) ? path : CommandLine.arguments[0])
        let response = try ProcessRunner.checked(worker, ["plugin-run", plugin.manifest.kind, plugin.entrypoint.path], environment: ["DIAL_PLUGIN_REQUEST": String(decoding: data, as: UTF8.self)], timeout: 5)
        let parsed = try JSONDecoder().decode(PluginResponse.self, from: Data(response.utf8))
        if let error = parsed.error { throw ConfigError(error) }
        if let url = parsed.openURL {
            guard let target = URL(string: url), target.scheme != nil else { throw ConfigError("URLを正しく指定してください") }
            guard DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(target) }) else { throw ConfigError("URLを開けませんでした") }
        }
        if let path = parsed.openPath {
            guard DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }) else { throw ConfigError("ファイルを開けませんでした") }
        }
        if let app = parsed.openApplication {
            _ = try ProcessRunner.checked("/usr/bin/open", ["-a", app], timeout: 5)
        }
        return parsed.message ?? ""
    }
}

public struct PluginRequest: Codable {
    public let action: String
    public let context: AppContext
    public let event: [String: String]
    public let settings: [String: String]
    public let amount: Double
    public let profile: String
    public let layer: String
}
public struct PluginResponse: Codable {
    public let error: String?
    public let message: String?
    public let openURL: String?
    public let openPath: String?
    public let openApplication: String?
}
