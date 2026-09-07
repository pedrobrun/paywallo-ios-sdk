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
    // MetaBridge.swift guards every FBSDK call with `#if canImport(FBSDKCoreKit)`,
    // but the target declared no dependency on the Meta SDK — so nothing ordered
    // the framework's copy into the products directory before this target's
    // dependency scan, and whether the Meta bridge existed was a build-ordering
    // race: same commit, one build compiles it in, the next compiles it out (as
    // an empty no-op returning nil). Declaring the edge makes the state
    // deterministic. Upstream should instead ship this as an opt-in product for
    // apps with no Meta integration; here it is unconditional on purpose.
    dependencies: [
        .package(url: "https://github.com/facebook/facebook-ios-sdk", from: "18.0.0")
    ],
    targets: [
        .target(
            name: "PaywalloSDK",
            dependencies: [
                .product(name: "FacebookCore", package: "facebook-ios-sdk")
            ],
            path: "Sources/PaywalloSDK"
        ),
        .testTarget(
            name: "PaywalloSDKTests",
            dependencies: ["PaywalloSDK"],
            path: "Tests/PaywalloSDKTests"
        )
    ]
)
