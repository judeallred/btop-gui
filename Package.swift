// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoBeachballs",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NoBeachballsCore"),
        .executableTarget(name: "NoBeachballs", dependencies: ["NoBeachballsCore"]),
        .testTarget(name: "NoBeachballsCoreTests", dependencies: ["NoBeachballsCore"]),
    ]
)
