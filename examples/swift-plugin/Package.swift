// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExamplePlugin",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ExamplePlugin", type: .dynamic, targets: ["ExamplePlugin"])],
    dependencies: [.package(path: "../../PluginSDK/Swift")],
    targets: [.target(name: "ExamplePlugin", dependencies: [.product(name: "DialPluginSDK", package: "Swift")])]
)
