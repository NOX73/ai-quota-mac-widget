// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeQuota",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ClaudeQuota",
            targets: ["ClaudeQuota"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClaudeQuota",
            dependencies: [],
            path: "Sources/ClaudeQuota"
        )
    ]
)

