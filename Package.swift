// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcdev",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "xcd", targets: ["xcd"]),
        .library(name: "XcdevKit", targets: ["XcdevKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "XcdevKit",
            dependencies: [.product(name: "Yams", package: "Yams")],
            exclude: ["UIRunner/Project"]
        ),
        .executableTarget(
            name: "xcd",
            dependencies: [
                "XcdevKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "XcdevTestSupport",
            dependencies: ["XcdevKit"],
            path: "Tests/XcdevTestSupport"
        ),
        .testTarget(
            name: "XcdevKitTests",
            dependencies: ["XcdevKit", "XcdevTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["XcdevKit", "XcdevTestSupport"]
        ),
    ]
)
