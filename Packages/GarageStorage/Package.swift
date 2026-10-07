// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageStorage",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "GarageStorage", targets: ["GarageStorage"])
    ],
    dependencies: [
        .package(path: "../GarageCore"),
        .package(path: "../GarageSync"),
        .package(path: "../GarageAPI"),
    ],
    targets: [
        .target(name: "GarageStorage", dependencies: ["GarageCore", "GarageSync", "GarageAPI"]),
        .testTarget(
            name: "GarageStorageTests", dependencies: ["GarageStorage", "GarageCore", "GarageSync", "GarageAPI"]),
    ]
)
