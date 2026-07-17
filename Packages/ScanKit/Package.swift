// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "scankit-bench", targets: ["ScanKitBench"])
    ],
    dependencies: [
        .package(path: "../TestHarness"),
        .package(path: "../LogKit"),
        .package(path: "../SafetyKit")
    ],
    targets: [
        .target(
            name: "ScanKit",
            dependencies: [
                "LogKit",
                "SafetyKit"
            ],
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
                "SafetyKit",
                .product(name: "TestHarness", package: "TestHarness")
            ],
            path: "Tests/ScanKitTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
