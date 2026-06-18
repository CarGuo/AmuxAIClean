// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TestHarness",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TestHarness", targets: ["TestHarness"])
    ],
    dependencies: [
        .package(path: "../ScanKit"),
        .package(path: "../SafetyKit")
    ],
    targets: [
        .target(
            name: "TestHarness",
            dependencies: ["ScanKit", "SafetyKit"],
            path: "Sources/TestHarness"
        ),
        .testTarget(
            name: "TestHarnessTests",
            dependencies: ["TestHarness"],
            path: "Tests/TestHarnessTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .executableTarget(
            name: "workflow-cli",
            dependencies: ["ScanKit"],
            path: "Sources/workflow-cli"
        )
    ]
)
