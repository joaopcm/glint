// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintEditor",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GlintEditor", targets: ["GlintEditor"])],
    targets: [
        .target(name: "GlintEditor"),
        .testTarget(name: "GlintEditorTests", dependencies: ["GlintEditor"]),
    ]
)
