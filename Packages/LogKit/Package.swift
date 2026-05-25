// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LogKit", targets: ["LogKit"])],
    targets: [
        .target(name: "LogKit", path: "Sources/LogKit"),
        .testTarget(name: "LogKitTests", dependencies: ["LogKit"], path: "Tests/LogKitTests")
    ]
)
