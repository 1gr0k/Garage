// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GarageCore", targets: ["GarageCore"])
    ],
    targets: [
        .target(name: "GarageCore"),
        .testTarget(name: "GarageCoreTests", dependencies: ["GarageCore"]),
    ]
)
