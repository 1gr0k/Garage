// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageAPI",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GarageAPI", targets: ["GarageAPI"])
    ],
    targets: [
        .target(name: "GarageAPI"),
        .testTarget(name: "GarageAPITests", dependencies: ["GarageAPI"]),
    ]
)
