// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCBox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CCBoxApp", targets: ["CCBoxApp"]),
        .executable(name: "ccbox-verify", targets: ["ccbox-verify"]),
        .executable(name: "CCBoxNetworkFilter", targets: ["CCBoxNetworkFilter"])
    ],
    targets: [
        .target(name: "SandboxPTY"),
        .target(name: "CCBoxNetworkFilterCore"),
        .target(name: "CCBoxCore", dependencies: ["SandboxPTY", "CCBoxNetworkFilterCore"], resources: [.copy("Resources/ImportNodes.rb")]),
        .executableTarget(name: "CCBoxNetworkFilter", dependencies: ["CCBoxNetworkFilterCore"]),
        .executableTarget(
            name: "CCBoxApp",
            dependencies: ["CCBoxCore", "CCBoxNetworkFilterCore"],
            resources: [.copy("Resources/xterm")]
        ),
        .executableTarget(
            name: "ccbox-verify",
            dependencies: ["CCBoxCore"]
        ),
        .testTarget(name: "CCBoxCoreTests", dependencies: ["CCBoxCore", "CCBoxNetworkFilterCore"])
    ]
)
