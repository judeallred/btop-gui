// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BtopGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BtopCore"),
        .executableTarget(name: "BtopGUI", dependencies: ["BtopCore"]),
        .testTarget(name: "BtopCoreTests", dependencies: ["BtopCore"]),
    ]
)
