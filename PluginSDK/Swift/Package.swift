// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DialPluginSDK",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DialPluginSDK", targets: ["DialPluginSDK"])],
    targets: [
        .target(name: "DialPluginSDK"),
        .testTarget(name: "DialPluginSDKTests", dependencies: ["DialPluginSDK"]),
    ]
)
