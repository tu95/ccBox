// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSandbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeSandboxApp", targets: ["ClaudeSandboxApp"]),
        .executable(name: "ccbox-verify", targets: ["ccbox-verify"]),
        .executable(name: "CCBoxNetworkFilter", targets: ["CCBoxNetworkFilter"])
    ],
    targets: [
        .target(name: "SandboxPTY"),
        .target(name: "CCBoxNetworkFilterCore"),
        .target(name: "ClaudeSandboxCore", dependencies: ["SandboxPTY", "CCBoxNetworkFilterCore"], resources: [.copy("Resources/ImportNodes.rb")]),
        .executableTarget(name: "CCBoxNetworkFilter", dependencies: ["CCBoxNetworkFilterCore"]),
        .executableTarget(
            name: "ClaudeSandboxApp",
            dependencies: ["ClaudeSandboxCore", "CCBoxNetworkFilterCore"],
            resources: [.copy("Resources/xterm")]
        ),
        .executableTarget(
            name: "ccbox-verify",
            dependencies: ["ClaudeSandboxCore"]
        ),
        .testTarget(name: "ClaudeSandboxCoreTests", dependencies: ["ClaudeSandboxCore", "CCBoxNetworkFilterCore"])
    ]
)
