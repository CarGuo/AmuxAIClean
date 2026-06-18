// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AIKit", targets: ["AIKit"])
    ],
    dependencies: [
        .package(path: "../LogKit"),
        .package(path: "../SafetyKit")
    ],
    targets: [
        .target(
            name: "AIKit",
            dependencies: ["LogKit", "SafetyKit"],
            path: "Sources/AIKit"
        ),
        .testTarget(
            name: "AIKitTests",
            dependencies: ["AIKit", "SafetyKit"],
            path: "Tests/AIKitTests"
        )
    ]
)
