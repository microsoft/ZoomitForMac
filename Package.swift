// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZoomItMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ZoomItMacCore", targets: ["ZoomItMacCore"]),
        .executable(name: "ZoomItMac", targets: ["ZoomItMac"]),
        .executable(name: "ZoomItMacSelfTest", targets: ["ZoomItMacSelfTest"])
    ],
    targets: [
        .target(
            name: "ZoomItMacCore",
            path: "Sources/ZoomItMacCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ZoomItMac",
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