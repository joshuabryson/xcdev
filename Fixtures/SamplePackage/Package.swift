// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SamplePackage",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SampleLib", targets: ["SampleLib"]),
    ],
    targets: [
        .target(name: "SampleLib"),
        .testTarget(name: "SampleLibTests", dependencies: ["SampleLib"]),
    ]
)
