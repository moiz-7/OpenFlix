// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenFlixCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openflix", targets: ["openflix"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "openflix",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/openflix",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
    ]
)
