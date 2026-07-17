// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafetyKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
    products: [.library(name: "SafetyKit", targets: ["SafetyKit"])],
    dependencies: [
        .package(path: "../LogKit")
    ],
    targets: [
        .target(
            name: "SafetyKit",
            dependencies: ["LogKit"],
            path: "Sources/SafetyKit",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SafetyKitTests", dependencies: ["SafetyKit"], path: "Tests/SafetyKitTests")
    ]
)
