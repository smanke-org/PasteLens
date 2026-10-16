// swift-tools-version: 6.2
import PackageDescription

// The shared logic lives in PasteLensKit, a plain Swift package so `swift test` runs it
// without Xcode. The app, the CLI and the MCP helper are built by project.yml (XcodeGen),
// which links this package: App Intents metadata only comes out of an Xcode build.
let package = Package(
    name: "PasteLensKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PasteLensKit", targets: ["PasteLensKit"]),
    ],
    targets: [
        .target(name: "PasteLensKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PasteLensKitTests", dependencies: ["PasteLensKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
