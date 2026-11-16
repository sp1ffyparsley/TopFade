// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TopFadeMac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TopFadeMac", targets: ["TopFadeMac"]),
    ],
    targets: [
        .executableTarget(
            name: "TopFadeMac",
            path: "Sources/TopFadeMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
