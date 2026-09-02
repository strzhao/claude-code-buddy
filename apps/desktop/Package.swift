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
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            from: "2.0.0"
        ),
        // capso-spm 已收编进本仓（仓库根 capso-spm/，BSL 1.1），
        // path 依赖不进 Package.resolved，跟随仓内源码即时生效
        .package(path: "../../capso-spm")
    ],
    targets: [
        .target(
            name: "BuddyCore",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "CaptureKit", package: "capso-spm"),
                .product(name: "AnnotationKit", package: "capso-spm")
            ],
            path: "Sources/ClaudeCodeBuddy",
            exclude: ["Resources", "App/main.swift"],
            resources: [
                .copy("Assets"),
                .copy("Marketplace")
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
                "buddy-cli",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/BuddyCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
