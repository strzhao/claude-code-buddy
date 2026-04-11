// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeBuddy",
    platforms: [
        .macOS(.v14)
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
        .testTarget(
            name: "BuddyCoreTests",
            dependencies: ["BuddyCore"],
            path: "Tests/BuddyCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
