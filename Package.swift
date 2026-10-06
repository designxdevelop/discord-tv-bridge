// swift-tools-version: 6.0
import PackageDescription

// Run Scripts/fetch-webrtc.sh first: it downloads the pinned, checksum-verified XCFramework into Vendor/.
let package = Package(
    name: "DiscordTVBridge",
    platforms: [.macOS(.v14), .tvOS(.v17)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"])],
    targets: [
        .binaryTarget(name: "LiveKitWebRTC", path: "Vendor/LiveKitWebRTC.xcframework"),
        .target(name: "BridgeCore", dependencies: ["LiveKitWebRTC"], path: "Sources/Shared"),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
