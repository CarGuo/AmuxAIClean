// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileSearchKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
    products: [
        .library(name: "FileSearchKit", targets: ["FileSearchKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FileSearchKit",
            dependencies: [],
            path: "Sources/FileSearchKit"
        ),
        .testTarget(
            name: "FileSearchKitTests",
            dependencies: ["FileSearchKit"],
            path: "Tests/FileSearchKitTests"
        )
    ]
)
