// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaywalloSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "PaywalloSDK",
            targets: ["PaywalloSDK"]
        )
    ],
    targets: [
        .target(
            name: "PaywalloSDK",
            path: "Sources/PaywalloSDK"
        ),
        .testTarget(
            name: "PaywalloSDKTests",
            dependencies: ["PaywalloSDK"],
            path: "Tests/PaywalloSDKTests"
        )
    ]
)
