// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SampleAppFeature",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SampleAppFeature",
            targets: ["SampleAppFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "SampleAppFeature",
            dependencies: [
                .product(name: "Hajime", package: "Hajime"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
