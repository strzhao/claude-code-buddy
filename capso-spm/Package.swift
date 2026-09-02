// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "capso-spm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "AnnotationKit", targets: ["AnnotationKit"]),
    ],
    targets: [
        .target(name: "SharedKit", path: "Sources/SharedKit"),
        .target(
            name: "CaptureKit",
            dependencies: ["SharedKit"],
            path: "Sources/CaptureKit"
        ),
        .target(
            name: "AnnotationKit",
            dependencies: ["SharedKit"],
            path: "Sources/AnnotationKit"
        ),
    ]
)
