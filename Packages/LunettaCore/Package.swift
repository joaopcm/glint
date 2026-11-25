// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunettaCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LunettaCore", targets: ["LunettaCore"])],
    targets: [
        .target(name: "LunettaCore"),
        .testTarget(name: "LunettaCoreTests", dependencies: ["LunettaCore"], resources: [.copy("Fixtures")]),
    ]
)
