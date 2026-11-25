// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunettaCapture",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LunettaCapture", targets: ["LunettaCapture"])],
    dependencies: [.package(path: "../LunettaCore")],
    targets: [
        .target(name: "LunettaCapture", dependencies: ["LunettaCore"]),
        .testTarget(name: "LunettaCaptureTests", dependencies: ["LunettaCapture"], resources: [.copy("Fixtures")]),
    ]
)
