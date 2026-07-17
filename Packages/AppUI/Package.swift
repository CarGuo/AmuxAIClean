// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppUI",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
    products: [.library(name: "AppUI", targets: ["AppUI"])],
    dependencies: [
        .package(path: "../ScanKit"),
        .package(path: "../SafetyKit"),
        .package(path: "../HeuristicKit"),
        .package(path: "../LogKit"),
        .package(path: "../BrewKit"),
        .package(path: "../AIKit")
    ],
    targets: [
        .target(
            name: "AppUI",
            dependencies: ["ScanKit", "SafetyKit", "HeuristicKit", "LogKit", "BrewKit", "AIKit"],
            path: "Sources/AppUI",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: ["AppUI", "AIKit", "SafetyKit"],
            path: "Tests/AppUITests"
        )
    ]
)
