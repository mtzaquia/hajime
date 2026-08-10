// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Hajime",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Hajime",
            targets: ["Hajime"]
        ),
    ],
    targets: [
        .target(name: "Hajime"),
        .testTarget(
            name: "HajimeTests",
            dependencies: ["Hajime"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
