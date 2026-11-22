// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSandbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeSandboxApp", targets: ["ClaudeSandboxApp"])
    ],
    targets: [
        .target(name: "SandboxPTY"),
        .target(name: "ClaudeSandboxCore", dependencies: ["SandboxPTY"], resources: [.copy("Resources/ImportNodes.rb")]),
        .executableTarget(
            name: "ClaudeSandboxApp",
            dependencies: ["ClaudeSandboxCore"],
            resources: [.copy("Resources/xterm")]
        ),
        .testTarget(name: "ClaudeSandboxCoreTests", dependencies: ["ClaudeSandboxCore"])
    ]
)
