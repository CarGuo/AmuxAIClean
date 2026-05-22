// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "scankit-bench", targets: ["ScanKitBench"])
    ],
    dependencies: [
        .package(path: "../TestHarness")
    ],
    targets: [
        .target(
            name: "ScanKit",
            path: "Sources/ScanKit"
        ),
        .executableTarget(
            name: "ScanKitBench",
            dependencies: ["ScanKit"],
            path: "Sources/ScanKitBench"
        ),
        .testTarget(
            name: "ScanKitTests",
            dependencies: [
                "ScanKit",
                .product(name: "TestHarness", package: "TestHarness")
            ],
            path: "Tests/ScanKitTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
