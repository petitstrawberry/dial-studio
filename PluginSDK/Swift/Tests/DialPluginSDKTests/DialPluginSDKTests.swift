import XCTest
@testable import DialPluginSDK

final class DialPluginSDKTests: XCTestCase {
    let input = #"{"action":"open","context":{"bundleID":"app","appName":"Name","title":"Title","url":""},"event":{"gesture":"press"},"settings":{"url":"https://example.com"},"amount":1,"profile":"Profile","layer":"Layer"}"#

    func testInvocationAndError() throws {
        let result = input.withCString { ptr in PluginRuntime.invoke(ptr) { request in
            XCTAssertEqual(request.context.bundleID, "app")
            XCTAssertEqual(request.event["gesture"], "press")
            return PluginResponse(openURL: request.settings["url"])
        } }
        let response = try JSONDecoder().decode(PluginResponse.self, from: Data(String(cString: XCTUnwrap(result)).utf8))
        XCTAssertEqual(response.openURL, "https://example.com")
        let error = "bad json".withCString { PluginRuntime.invoke($0) { _ in PluginResponse() } }
        let failed = try JSONDecoder().decode(PluginResponse.self, from: Data(String(cString: XCTUnwrap(error)).utf8))
        XCTAssertNotNil(failed.error)
    }
    func testManifestUsesHostFieldNames() throws {
        let manifest = PluginManifest(id: "example", name: "Example", version: "1", kind: "dylib", entrypoint: "plugin.dylib", actions: [.init(id: "go", title: "Go", fields: [.init(id: "url", title: "URL", defaultValue: "https://example.com")])])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        let actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
        let fields = try XCTUnwrap(actions[0]["fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["defaultValue"] as? String, "https://example.com")
    }
}
