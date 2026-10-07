// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageServer",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "../Packages/GarageAPI"),
        .package(path: "../Packages/GarageCore"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
                "GarageAPI",
                "GarageCore",
            ]
        ),
        .executableTarget(name: "GarageServer", dependencies: ["App"]),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "VaporTesting", package: "vapor"),
                "GarageAPI",
                "GarageCore",
            ]
        ),
    ]
)
