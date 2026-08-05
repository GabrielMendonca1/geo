// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GeoCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "GeoCore", targets: ["GeoCore"])
    ],
    targets: [
        .target(name: "GeoCore"),
        .testTarget(name: "GeoCoreTests", dependencies: ["GeoCore"])
    ]
)
