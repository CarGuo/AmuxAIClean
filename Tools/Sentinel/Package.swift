// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sentinel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gsycleanmac-sentinel", targets: ["Sentinel"])
    ],
    targets: [
        .executableTarget(
            name: "Sentinel",
            path: "Sources/Sentinel",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "SentinelTests",
            dependencies: ["Sentinel"],
            path: "Tests/SentinelTests"
        )
    ]
)
