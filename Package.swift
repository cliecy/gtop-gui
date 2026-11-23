// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GTop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GTopCore", targets: ["GTopCore"]),
        .executable(name: "GTop", targets: ["GTopApp"])
    ],
    targets: [
        .target(
            name: "GTopCore",
            path: "Sources/GTopCore"
        ),
        .executableTarget(
            name: "GTopApp",
            dependencies: ["GTopCore"],
            path: "Sources/GTopApp"
        ),
        .testTarget(
            name: "GTopCoreTests",
            dependencies: ["GTopCore"],
            path: "Tests/GTopCoreTests"
        )
    ]
)
