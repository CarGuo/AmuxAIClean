// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AppUI", targets: ["AppUI"])],
    dependencies: [
        .package(path: "../ScanKit"),
        .package(path: "../SafetyKit"),
        .package(path: "../XPCBridge"),
        .package(path: "../HeuristicKit")
    ],
    targets: [
        .target(
            name: "AppUI",
            dependencies: ["ScanKit", "SafetyKit", "XPCBridge", "HeuristicKit"],
            path: "Sources/AppUI"
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: ["AppUI"],
            path: "Tests/AppUITests"
        )
    ]
)
