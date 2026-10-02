// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Playa",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Prebuilt, self-contained libmpv (LGPL build) for macOS, iOS and tvOS.
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "0.41.0"),
    ],
    targets: [
        .target(name: "PlayaCore"),
        .executableTarget(
            name: "Playa",
            dependencies: [
                "PlayaCore",
                .product(name: "MPVKit", package: "MPVKit"),
            ]
        ),
        .testTarget(
            name: "PlayaCoreTests",
            dependencies: ["PlayaCore"]
        ),
    ]
)
