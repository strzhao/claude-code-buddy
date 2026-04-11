// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeBuddy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeBuddy",
            path: "Sources/ClaudeCodeBuddy",
            exclude: ["Resources"],
            resources: [
                .copy("Assets")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
