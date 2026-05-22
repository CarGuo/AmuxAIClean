// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeuristicKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeuristicKit", targets: ["HeuristicKit"])
    ],
    dependencies: [
        .package(path: "../SafetyKit")
    ],
    targets: [
        .target(
            name: "HeuristicKit",
            dependencies: ["SafetyKit"],
            path: "Sources/HeuristicKit"
        ),
        .testTarget(
            name: "HeuristicKitTests",
            dependencies: ["HeuristicKit", "SafetyKit"],
            path: "Tests/HeuristicKitTests"
        )
    ]
)
