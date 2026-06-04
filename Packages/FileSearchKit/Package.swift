// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileSearchKit",
    platforms: [.macOS(.v15)],
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
