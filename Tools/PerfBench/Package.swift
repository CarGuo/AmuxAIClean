// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PerfBench",
    // v2026.07.16: benchmarks compile against the same Ventura 13.5 floor as the product.
    platforms: [.macOS("13.5")],
    products: [
        .executable(name: "PerfBench", targets: ["PerfBench"])
    ],
    dependencies: [
        .package(path: "../../Packages/ScanKit")
    ],
    targets: [
        .executableTarget(
            name: "PerfBench",
            dependencies: [
                .product(name: "ScanKit", package: "ScanKit")
            ],
            path: "Sources/PerfBench",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug))
            ]
        )
    ]
)
