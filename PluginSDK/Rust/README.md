# Dial Studio Rust plugin SDK

Create WebAssembly actions for [Dial Studio](https://github.com/petitstrawberry/dial-studio). The SDK provides typed requests and responses and exports the host ABI.

Before the crate is published, add it from Git:

```toml
[dependencies]
dial-plugin-sdk = { git = "https://github.com/petitstrawberry/dial-studio.git", rev = "<commit-containing-the-sdk>" }

[lib]
crate-type = ["cdylib"]
```

Replace the revision with a commit that contains the SDK. After publication on crates.io, a version dependency such as `dial-plugin-sdk = "0.1"` can be used instead.

```rust
use dial_plugin_sdk::{export_plugin, Request, Response};

fn handle(request: Request) -> Result<Response, String> {
    let url = request.settings.get("url").ok_or("URL is required")?;
    Ok(Response { open_url: Some(url.clone()), ..Response::default() })
}

export_plugin!(handle);
```

Build with `cargo build --release --target wasm32-unknown-unknown`. Put the resulting `.wasm` and a `manifest.json` in a `.dialplugin` folder. See the [plugin guide](https://github.com/petitstrawberry/dial-studio/blob/main/docs/plugins.md) for packaging, manifests, and execution limitations. WASI and imported host functions are not available; each invocation gets a fresh module instance.

Licensed under MIT; see [LICENSE](LICENSE).
