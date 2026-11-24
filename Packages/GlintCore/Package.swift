// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GlintCore", targets: ["GlintCore"])],
    targets: [
        .target(name: "GlintCore"),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"], resources: [.copy("Fixtures")]),
    ]
)
