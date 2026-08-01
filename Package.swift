// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ScreenClear",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenClear",
            path: "Sources/ScreenClear"
        ),
        .testTarget(
            name: "ScreenClearTests",
            dependencies: ["ScreenClear"],
            path: "Tests/ScreenClearTests"
        )
    ]
)
