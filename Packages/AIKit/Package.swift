// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
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
