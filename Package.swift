// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LaPlaya",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "Cmpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .target(name: "LaPlayaCore"),
        .executableTarget(
            name: "LaPlaya",
            dependencies: ["Cmpv", "LaPlayaCore"]
        ),
        .testTarget(
            name: "LaPlayaCoreTests",
            dependencies: ["LaPlayaCore"]
        ),
    ]
)
