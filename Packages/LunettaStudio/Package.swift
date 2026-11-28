// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunettaStudio",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LunettaStudio", targets: ["LunettaStudio"])],
    dependencies: [.package(path: "../LunettaCore")],
    targets: [
        .target(name: "LunettaStudio", dependencies: ["LunettaCore"]),
        .executableTarget(name: "RenderBenchmark", dependencies: ["LunettaStudio", "LunettaCore"]),
        .testTarget(name: "LunettaStudioTests", dependencies: ["LunettaStudio"]),
    ]
)
