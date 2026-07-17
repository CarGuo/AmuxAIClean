// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogKit",
    // v2026.07.16: the product compatibility contract starts at Ventura 13.5.
    platforms: [.macOS("13.5")],
    products: [.library(name: "LogKit", targets: ["LogKit"])],
    targets: [
        .target(name: "LogKit", path: "Sources/LogKit"),
        .testTarget(name: "LogKitTests", dependencies: ["LogKit"], path: "Tests/LogKitTests")
    ]
)
