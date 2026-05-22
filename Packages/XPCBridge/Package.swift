// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XPCBridge",
    platforms: [.macOS(.v15)],
    products: [.library(name: "XPCBridge", targets: ["XPCBridge"])],
    targets: [
        .target(name: "XPCBridge", path: "Sources/XPCBridge"),
        .testTarget(
            name: "XPCBridgeTests",
            dependencies: ["XPCBridge"],
            path: "Tests/XPCBridgeTests"
        )
    ]
)
