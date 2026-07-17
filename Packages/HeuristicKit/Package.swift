// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeuristicKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
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
