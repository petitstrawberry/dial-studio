import XCTest
@testable import UlanziKit

final class PluginTests: XCTestCase {
    private func wasmFixture() -> Data {
        func section(_ id: UInt8, _ bytes: [UInt8]) -> [UInt8] { [id, UInt8(bytes.count)] + bytes }
        func name(_ value: String) -> [UInt8] { [UInt8(value.utf8.count)] + Array(value.utf8) }
        let output = Array("{\"message\":\"wasm ok\"}".utf8)
        var bytes: [UInt8] = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
        bytes += section(1, [3, 0x60, 1, 0x7f, 1, 0x7f, 0x60, 2, 0x7f, 0x7f, 1, 0x7f, 0x60, 0, 1, 0x7f])
        bytes += section(3, [3, 0, 1, 2])
        bytes += section(5, [1, 0, 1])
        bytes += section(7, [4] + name("memory") + [2, 0] + name("dial_alloc") + [0, 0] + name("dial_run") + [0, 1] + name("dial_result_len") + [0, 2])
        bytes += section(10, [3, 5, 0, 0x41, 0x80, 0x01, 0x0b, 4, 0, 0x41, 0, 0x0b, 4, 0, 0x41, UInt8(output.count), 0x0b])
        bytes += section(11, [1, 0, 0x41, 0, 0x0b, UInt8(output.count)] + output)
        return Data(bytes)
    }

    func testWasmExecutesAndRejectsInvalidModule() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wasm")
        defer { try? FileManager.default.removeItem(at: file) }
        try wasmFixture().write(to: file)
        XCTAssertEqual(try PluginHost.run(kind: "wasm", path: file.path, request: "{}"), "{\"message\":\"wasm ok\"}")
        try Data([0]).write(to: file)
        XCTAssertThrowsError(try PluginHost.run(kind: "wasm", path: file.path, request: "{}"))
    }

    func testDiscoverySettingsAndWasmWorker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Example.dialplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        {"id":"example.test","name":"Example","version":"1","author":"Author","description":"Description","license":"MIT","kind":"wasm","entrypoint":"plugin.wasm","actions":[{"id":"go","title":"Go","relative":true,"fields":[{"id":"target","title":"Target","defaultValue":"value"}]}]}
        """
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        try wasmFixture().write(to: bundle.appendingPathComponent("plugin.wasm"))
        let result = PluginRegistry.scan(at: root)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.plugins.first?.manifest.author, "Author")
        XCTAssertEqual(result.plugins.first?.manifest.description, "Description")
        XCTAssertEqual(result.plugins.first?.manifest.license, "MIT")
        let template = try XCTUnwrap(PluginRegistry.templates(result.plugins).first)
        XCTAssertEqual(template.action.pluginSettings?["target"], "value")
        var config = StudioConfiguration(profiles: [StudioProfile()])
        let profile = config.profiles[0], layer = profile.pages[0].layers[0]
        let change = try config.assign(template, profileID: profile.id, layerID: layer.id, control: .dial, gesture: .counterclockwise)
        let binding = try XCTUnwrap(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == change.bindingID })
        XCTAssertEqual(binding.action.amount, -1)
        try config.validate()
        let invocation = ActionInvocation(binding: binding, profile: profile, layer: layer, context: AppContext(bundleID: "example.app"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = project.appendingPathComponent(".build/debug/ulanzid")
        XCTAssertEqual(try PluginRegistry.execute(invocation, at: root, worker: worker), "wasm ok")
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("plugin.wasm"))
        XCTAssertThrowsError(try PluginRegistry.execute(invocation, at: root, worker: worker))
        try config.validate() // A missing plugin does not discard or prevent saving assignments.
    }

    func testInvalidEntrypointAndDuplicateIDsAreReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B"] {
            let bundle = root.appendingPathComponent(name + ".dialplugin", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("{\"id\":\"same\",\"name\":\"Example\",\"version\":\"1\",\"kind\":\"wasm\",\"entrypoint\":\"plugin.wasm\",\"actions\":[{\"id\":\"a\",\"title\":\"A\"}]}".utf8).write(to: bundle.appendingPathComponent("manifest.json"))
            try wasmFixture().write(to: bundle.appendingPathComponent("plugin.wasm"))
        }
        XCTAssertEqual(PluginRegistry.scan(at: root).plugins.count, 1)
        XCTAssertNil(PluginRegistry.scan(at: root).plugins.first?.manifest.author)
        XCTAssertEqual(PluginRegistry.scan(at: root).errors.count, 1)
        let bad = root.appendingPathComponent("A.dialplugin/manifest.json")
        try Data("{\"id\":\"bad\",\"name\":\"Bad\",\"version\":\"1\",\"kind\":\"dylib\",\"entrypoint\":\"../../escape.dylib\",\"actions\":[{\"id\":\"a\",\"title\":\"A\"}]}".utf8).write(to: bad)
        XCTAssertThrowsError(try PluginRegistry.load(root.appendingPathComponent("A.dialplugin")))
    }

    func testNativePluginReceivesRequestInWorkerAndReportsErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Native.dialplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("native.c")
        let dylib = bundle.appendingPathComponent("native.dylib")
        let code = """
        #include <string.h>
        const char *dial_plugin_run(const char *input) {
            return strstr(input, "needle") ? "{\\\"message\\\":\\\"native ok\\\"}" : "{\\\"error\\\":\\\"missing setting\\\"}";
        }
        """
        try Data(code.utf8).write(to: source)
        _ = try ProcessRunner.checked("/usr/bin/clang", ["-dynamiclib", source.path, "-o", dylib.path], timeout: 15)
        let manifest = """
        {"id":"example.native","name":"Native","version":"1","kind":"dylib","entrypoint":"native.dylib","actions":[{"id":"go","title":"Go","fields":[{"id":"target","title":"Target","defaultValue":"needle"}]}]}
        """
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        let template = try XCTUnwrap(PluginRegistry.templates(PluginRegistry.scan(at: root).plugins).first)
        let profile = StudioProfile(), layer = profile.pages[0].layers[0]
        let binding = StudioBinding(control: .topLeft, gesture: .press, action: template.action)
        let invocation = ActionInvocation(binding: binding, profile: profile, layer: layer, context: AppContext(bundleID: "example.app"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = project.appendingPathComponent(".build/debug/ulanzid")
        XCTAssertEqual(try PluginRegistry.execute(invocation, at: root, worker: worker), "native ok")
        var other = binding; other.action.pluginSettings = ["target": "other"]
        XCTAssertThrowsError(try PluginRegistry.execute(ActionInvocation(binding: other, profile: profile, layer: layer, context: AppContext()), at: root, worker: worker))
    }
}
