# Releasing the plugin SDKs

The Swift SDK is the `DialPluginSDK` product of the repository's root Swift package. The Rust SDK is the `dial-plugin-sdk` crate under `PluginSDK/Rust`. Both are MIT licensed. Release versions should document host compatibility and use semantic versioning; repository tags used by Swift Package Manager apply to the entire repository.

Before publishing a version:

1. Commit the SDK and host changes and run the SDK tests and example builds.
2. Update the crate version in `PluginSDK/Rust/Cargo.toml` and review its README, license, and release notes. Check the chosen crate name on crates.io; the name is not reserved by this repository.
3. Run `cargo package --manifest-path PluginSDK/Rust/Cargo.toml --list` and `cargo publish --manifest-path PluginSDK/Rust/Cargo.toml --dry-run`.
4. Push the reviewed commit. For version-based Swift dependencies, create and push a matching semantic version tag (for example `0.1.0`) only when that version is ready. Until then users can pin the commit revision.
5. Publish the crate with `cargo publish --manifest-path PluginSDK/Rust/Cargo.toml` using a crates.io account authorized for the crate name. Registry publication and pushing tags are separate actions.

After publication, users can reference Swift with `.package(url: "https://github.com/petitstrawberry/dial-studio.git", from: "0.1.0")` and Rust with `dial-plugin-sdk = "0.1"`, replacing those versions with the actual releases. No publishing credentials belong in the repository.
