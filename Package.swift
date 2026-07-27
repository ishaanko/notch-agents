// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchAgents",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchAgents", targets: ["NotchAgents"]),
        .executable(name: "NotchAgentsBridge", targets: ["NotchAgentsBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "NotchAgents",
            path: "Sources/NotchAgents",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NotchAgentsBridge",
            path: "Sources/NotchAgentsBridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
