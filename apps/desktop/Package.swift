// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeBuddy",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            from: "1.17.0"
        )
    ],
    targets: [
        .target(
            name: "BuddyCore",
            path: "Sources/ClaudeCodeBuddy",
            exclude: ["Resources", "App/main.swift"],
            resources: [
                .copy("Assets")
            ]
        ),
        .executableTarget(
            name: "ClaudeCodeBuddy",
            dependencies: ["BuddyCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "buddy-cli",
            path: "Sources/BuddyCLI"
        ),
        .testTarget(
            name: "BuddyCoreTests",
            dependencies: [
                "BuddyCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/BuddyCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
