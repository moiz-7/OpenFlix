// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenFlixCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openflix", targets: ["openflix"]),
        .library(name: "OpenFlixKit", targets: ["OpenFlixKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "OpenFlixKit",
            path: "Sources/OpenFlixKit"
        ),
        .executableTarget(
            name: "openflix",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "OpenFlixKit",
            ],
            path: "Sources/openflix",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "openflixTests",
            dependencies: ["openflix"],
            path: "Tests/openflixTests"
        ),
        .testTarget(
            name: "OpenFlixKitTests",
            dependencies: ["OpenFlixKit"],
            path: "Tests/OpenFlixKitTests"
        ),
    ]
)
