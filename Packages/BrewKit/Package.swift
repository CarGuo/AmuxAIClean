// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrewKit",
    platforms: [.macOS(.v15)],
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
