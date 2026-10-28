# Plugin development

A `.dialplugin` folder contains `manifest.json` and a native `.dylib` or a `.wasm` module. Add the folder in Dial Studio's settings; its actions appear in the palette. Each assignment stores its own field values. Missing plugins do not remove saved assignments; reinstall the plugin to use them again.

## SDKs and examples

Use [DialPluginSDK for Swift](../PluginSDK/Swift) for native plugins, or [dial-plugin-sdk for Rust](../PluginSDK/Rust) for WebAssembly. Both provide typed manifests, requests and responses and handle JSON and the host ABI. The [Swift example](../examples/swift-plugin) and [Rust example](../examples/rust-plugin) show a complete action and manifest. Once the changes are pushed, external projects can depend on the Git repository at a pinned revision; each SDK's README has the dependency declaration. The Rust crate can also be published to crates.io.

To build and package the examples from the repository root:

```sh
swift build -c release --package-path examples/swift-plugin
mkdir -p /tmp/SwiftExample.dialplugin
cp examples/swift-plugin/manifest.json /tmp/SwiftExample.dialplugin/
cp examples/swift-plugin/.build/release/libExamplePlugin.dylib /tmp/SwiftExample.dialplugin/

rustup target add wasm32-unknown-unknown
cargo build --release --target wasm32-unknown-unknown --manifest-path examples/rust-plugin/Cargo.toml
mkdir -p /tmp/RustExample.dialplugin
cp examples/rust-plugin/manifest.json /tmp/RustExample.dialplugin/
cp examples/rust-plugin/target/wasm32-unknown-unknown/release/dial_example_rust.wasm /tmp/RustExample.dialplugin/
```

Select either resulting `.dialplugin` folder using **Settings → Plugins → Add Plugin**. For a native plugin, export one C entry point that calls `PluginRuntime.invoke`; for Rust, `export_plugin!(handler)` supplies the Wasm exports. See the examples for the full signatures.

```json
{
  "id": "org.example.tools",
  "name": "Example Tools",
  "version": "1.0.0",
  "author": "Example Author",
  "description": "Example actions for Dial Studio.",
  "license": "MIT",
  "kind": "dylib",
  "entrypoint": "plugin.dylib",
  "actions": [{
    "id": "example",
    "title": "Example",
    "symbol": "sparkles",
    "relative": false,
    "fields": [{"id": "target", "title": "Target", "defaultValue": ""}]
  }]
}
```

IDs use letters, digits, dots, underscores, and hyphens; plugin IDs must be unique. `author`, `description`, `license`, `symbol`, `relative`, `fields`, and `defaultValue` are optional. Plugin information appears in settings. Fields are text values displayed in the inspector. Set `relative` for actions that need a signed amount for dial rotation.

## Invocation

Each invocation runs in a separate worker with a five-second timeout. The plugin receives UTF-8 JSON containing `action`, `context` (`bundleID`, `appName`, `title`, `url`), `event` (`control`, `gesture`, `pressID`, `bindingID`, `profileID`, `layerID`), `settings`, `amount`, `profile`, and `layer`. `pressID` is empty for rotation. The result is a UTF-8 JSON object. It can contain `message`, `error`, `openURL`, `openPath`, or `openApplication`; the host performs the requested open operation after the worker returns.

Workers and module instances are short-lived: they do not retain in-memory state between invocations or provide a background event loop. Native code has the user's permissions; install only plugins you trust.

Native libraries export the C ABI function `const char *dial_plugin_run(const char *request_json)`. Return a null-terminated UTF-8 JSON string that remains valid until the worker has copied it. The library runs with the user's permissions in the worker process.

Wasm modules export `memory`, `dial_alloc(size: i32) -> i32`, `dial_run(ptr: i32, len: i32) -> i32`, and `dial_result_len() -> i32`. The host writes the request at the pointer returned by `dial_alloc`; `dial_run` returns the result pointer and `dial_result_len` returns its byte length. Modules use the WebAssembly core API without imports; WASI is not currently provided. Result and request sizes are limited to 64 KiB.

The bundled Utilities plugin demonstrates the native interface in [UtilityPlugin.m](../Support/UtilityPlugin.m); a minimal WebAssembly example is in [hello-wasm](../examples/hello-wasm.dialplugin). Plugins use Dial Studio's own interface; Stream Deck and BetterTouchTool plugins are not directly compatible.
