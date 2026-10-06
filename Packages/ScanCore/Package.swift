// swift-tools-version:5.9
//
// ScanCore — platform-independent scanning domain, geometry processing,
// measurement and export logic for the LiDAR Scanner app.
//
// This package deliberately imports only Foundation and the Swift standard
// library (SIMD types). It contains NO ARKit / RoomPlan / SceneKit code, so
// every algorithm in here can be unit tested on macOS, in the iOS Simulator,
// or on Linux without LiDAR hardware (`swift test`).
import PackageDescription

let package = Package(
    name: "ScanCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"])
    ],
    targets: [
        .target(name: "ScanCore"),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"])
    ]
)
