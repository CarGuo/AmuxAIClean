// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoordinatorBench",
    // v2026.07.16: benchmarks compile against the same Ventura 13.5 floor as the product.
    platforms: [.macOS("13.5")],
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
