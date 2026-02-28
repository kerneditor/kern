// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "kern-bench",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "kern-bench",
            path: "Sources/KernBench",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "KernBenchTests",
            dependencies: ["kern-bench"],
            path: "Tests/KernBenchTests"
        ),
    ]
)
