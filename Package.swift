// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "FlowCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Flow",
            dependencies: ["FlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "FlowCoreTests", dependencies: ["FlowCore"]),
    ]
)
