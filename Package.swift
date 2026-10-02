// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Playa",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "Cmpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .target(name: "PlayaCore"),
        .executableTarget(
            name: "Playa",
            dependencies: ["Cmpv", "PlayaCore"]
        ),
        .testTarget(
            name: "PlayaCoreTests",
            dependencies: ["PlayaCore"]
        ),
    ]
)
