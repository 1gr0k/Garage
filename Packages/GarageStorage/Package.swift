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
        .package(path: "../GarageCore")
    ],
    targets: [
        .target(name: "GarageStorage", dependencies: ["GarageCore"]),
        .testTarget(name: "GarageStorageTests", dependencies: ["GarageStorage"]),
    ]
)
