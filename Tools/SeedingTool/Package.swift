// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SeedingTool",
    // v2026.07.16: fixtures use the exact product floor instead of a broader major-only target.
    platforms: [.macOS("13.5")],
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
