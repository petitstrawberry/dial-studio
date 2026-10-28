# Dial Studio Swift plugin SDK

Once the commit containing the SDK has been pushed, add the repository as a Swift Package dependency, using a specific commit:

```swift
platforms: [.macOS(.v14)],
dependencies: [
    .package(url: "https://github.com/petitstrawberry/dial-studio.git", revision: "<commit-containing-the-sdk>")
],
targets: [
    .target(name: "MyPlugin", dependencies: [
        .product(name: "DialPluginSDK", package: "dial-studio")
    ])
]
```

Replace the revision with the actual commit hash. Export a dynamic library and define its entry point:

```swift
import DialPluginSDK

@_cdecl("dial_plugin_run")
public func dialPluginRun(_ input: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    PluginRuntime.invoke(input) { request in
        guard let url = request.settings["url"], !url.isEmpty else {
            return PluginResponse(error: "URL is required")
        }
        return PluginResponse(openURL: url)
    }
}
```

The returned string remains valid until the next `PluginRuntime.invoke` in the same process. See the [plugin guide](https://github.com/petitstrawberry/dial-studio/blob/main/docs/plugins.md) and [example](https://github.com/petitstrawberry/dial-studio/tree/main/examples/swift-plugin) for packaging and the manifest. Native plugins run with the user's permissions. Licensed under [MIT](https://github.com/petitstrawberry/dial-studio/blob/main/LICENSE).
