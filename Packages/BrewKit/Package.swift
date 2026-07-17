// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrewKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
    products: [
        .library(name: "BrewKit", targets: ["BrewKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BrewKit",
            dependencies: [],
            path: "Sources/BrewKit"
        ),
        .testTarget(
            name: "BrewKitTests",
            dependencies: ["BrewKit"],
            path: "Tests/BrewKitTests"
        )
    ]
)
