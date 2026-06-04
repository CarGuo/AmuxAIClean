// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LipoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LipoKit", targets: ["LipoKit"])
    ],
    targets: [
        .target(
            name: "LipoKit",
            path: "Sources/LipoKit"
        ),
        .testTarget(
            name: "LipoKitTests",
            dependencies: ["LipoKit"],
            path: "Tests/LipoKitTests"
        )
    ]
)
