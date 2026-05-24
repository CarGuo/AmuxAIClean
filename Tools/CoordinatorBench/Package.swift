// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoordinatorBench",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CoordinatorBench", targets: ["CoordinatorBench"])
    ],
    dependencies: [
        .package(path: "../../Packages/AppUI")
    ],
    targets: [
        .executableTarget(
            name: "CoordinatorBench",
            dependencies: [
                .product(name: "AppUI", package: "AppUI")
            ],
            path: "Sources/CoordinatorBench",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
