// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalRecorder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "LocalRecorder", targets: ["LocalRecorder"]),
        .executable(name: "RecorderCoreHarness", targets: ["RecorderCoreHarness"])
    ],
    targets: [
        .target(
            name: "RecorderCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .executableTarget(
            name: "LocalRecorder",
            dependencies: ["RecorderCore"],
            path: "Sources/LocalRecorderApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "RecorderCoreHarness",
            dependencies: ["RecorderCore"],
            path: "ValidationHarness"
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"]
        )
    ]
)
