import Foundation
import Darwin

public struct PluginManifest: Codable {
    public struct Field: Codable {
        public var id: String, title: String
        public var defaultValue: String?
        public init(id: String, title: String, defaultValue: String? = nil) {
            self.id = id; self.title = title; self.defaultValue = defaultValue
        }
    }
    public struct Action: Codable {
        public var id: String, title: String
        public var symbol: String?
        public var relative: Bool?
        public var fields: [Field]?
        public init(id: String, title: String, symbol: String? = nil, relative: Bool? = nil, fields: [Field]? = nil) {
            self.id = id; self.title = title; self.symbol = symbol; self.relative = relative; self.fields = fields
        }
    }
    public var id: String, name: String, version: String, kind: String, entrypoint: String
    public var author: String?, description: String?, license: String?
    public var actions: [Action]
    public init(id: String, name: String, version: String, kind: String, entrypoint: String,
                author: String? = nil, description: String? = nil, license: String? = nil, actions: [Action]) {
        self.id = id; self.name = name; self.version = version; self.kind = kind; self.entrypoint = entrypoint
        self.author = author; self.description = description; self.license = license; self.actions = actions
    }
}

public struct PluginContext: Codable {
    public let bundleID: String
    public let appName: String
    public let title: String
    public let url: String
}

public struct PluginRequest: Codable {
    public let action: String
    public let context: PluginContext
    public let event: [String: String]
    public let settings: [String: String]
    public let amount: Double
    public let profile: String
    public let layer: String
}

public struct PluginResponse: Codable {
    public var message: String?
    public var error: String?
    public var openURL: String?
    public var openPath: String?
    public var openApplication: String?

    public init(message: String? = nil, error: String? = nil, openURL: String? = nil,
                openPath: String? = nil, openApplication: String? = nil) {
        self.message = message; self.error = error; self.openURL = openURL
        self.openPath = openPath; self.openApplication = openApplication
    }
}

/// The returned C string is valid until the next invocation in this process.
public enum PluginRuntime {
    private static let lock = NSLock()
    private static var output: UnsafeMutablePointer<CChar>?

    public static func invoke(_ input: UnsafePointer<CChar>?, handler: (PluginRequest) throws -> PluginResponse) -> UnsafePointer<CChar>? {
        lock.lock(); defer { lock.unlock() }
        let response: PluginResponse
        do {
            guard let input else { throw RuntimeError.missingInput }
            let request = try JSONDecoder().decode(PluginRequest.self, from: Data(String(cString: input).utf8))
            response = try handler(request)
        } catch { response = PluginResponse(error: String(describing: error)) }
        let data = (try? JSONEncoder().encode(response)) ?? Data("{\"error\":\"Encoding failed\"}".utf8)
        if let output { free(output) }
        output = strdup(String(decoding: data, as: UTF8.self))
        return output.map { UnsafePointer($0) }
    }
    private enum RuntimeError: Error { case missingInput }
}
