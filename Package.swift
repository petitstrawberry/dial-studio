// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ulanzid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ulanzid", targets: ["ulanzid"]),
        .executable(name: "DialStudio", targets: ["DialStudio"]),
        .library(name: "UlanziKit", targets: ["UlanziKit"]),
        .library(name: "DialPluginSDK", targets: ["DialPluginSDK"]),
    ],
    targets: [
        .target(name: "DialPluginSDK", path: "PluginSDK/Swift/Sources/DialPluginSDK"),
        .target(
            name: "UlanziKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("JavaScriptCore"),
            ]
        ),
        .executableTarget(name: "ulanzid", dependencies: ["UlanziKit"]),
        .executableTarget(name: "DialStudio", dependencies: ["UlanziKit"]),
        .testTarget(name: "UlanziKitTests", dependencies: ["UlanziKit"]),
        .testTarget(name: "DialStudioTests", dependencies: ["DialStudio", "UlanziKit"]),
    ]
)
