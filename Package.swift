// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacWhisperAuto",
    platforms: [
        .macOS(.v15)  // macOS 26 Tahoe; SPM uses marketing version
    ],
    products: [
        .executable(name: "MacWhisperAuto", targets: ["MacWhisperAuto"])
    ],
    targets: [
        .executableTarget(
            name: "MacWhisperAuto",
            path: "Sources"
        )
    ]
)
