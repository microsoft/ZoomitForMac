// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZoomItMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ZoomItMacCore", targets: ["ZoomItMacCore"]),
        .executable(name: "ZoomIt", targets: ["ZoomIt"]),
        .executable(name: "ZoomItMacSelfTest", targets: ["ZoomItMacSelfTest"])
    ],
    targets: [
        .target(
            name: "ZoomItMacCore",
            path: "Sources/ZoomItMacCore",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ZoomIt",
            dependencies: ["ZoomItMacCore"],
            path: "Sources/ZoomItMacApp",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ZoomItMacSelfTest",
            dependencies: ["ZoomItMacCore"],
            path: "Sources/ZoomItMacSelfTest",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)