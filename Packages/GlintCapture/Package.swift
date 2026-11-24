// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintCapture",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GlintCapture", targets: ["GlintCapture"])],
    dependencies: [.package(path: "../GlintCore")],
    targets: [
        .target(name: "GlintCapture", dependencies: ["GlintCore"]),
        .testTarget(name: "GlintCaptureTests", dependencies: ["GlintCapture"], resources: [.copy("Fixtures")]),
    ]
)
