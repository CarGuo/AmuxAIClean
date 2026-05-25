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
        .package(path: "../TestHarness"),
        .package(path: "../LogKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "ScanKit",
            dependencies: [
                "LogKit",
                .product(name: "GRDB", package: "GRDB.swift")
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
                .product(name: "TestHarness", package: "TestHarness")
            ],
            path: "Tests/ScanKitTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
