// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageSync",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GarageSync", targets: ["GarageSync"])
    ],
    dependencies: [
        .package(path: "../GarageCore"),
        .package(path: "../GarageAPI"),
    ],
    targets: [
        .target(name: "GarageSync", dependencies: ["GarageCore", "GarageAPI"]),
        .testTarget(name: "GarageSyncTests", dependencies: ["GarageSync", "GarageCore", "GarageAPI"]),
    ]
)
