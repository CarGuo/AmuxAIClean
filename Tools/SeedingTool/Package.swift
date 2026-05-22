// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SeedingTool",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "seeding-tool", targets: ["SeedingTool"])
    ],
    targets: [
        .executableTarget(
            name: "SeedingTool",
            path: "Sources/SeedingTool",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug))
            ]
        )
    ]
)
