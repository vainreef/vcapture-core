// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VCaptureCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VCaptureCore",
            targets: ["VCaptureCore"]
        )
    ],
    targets: [
        .target(
            name: "VCaptureCore",
            path: "Sources/VCaptureCore"
        )
    ]
)
