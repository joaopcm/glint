// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunettaEditor",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LunettaEditor", targets: ["LunettaEditor"])],
    dependencies: [.package(path: "../LunettaUI")],
    targets: [
        .target(name: "LunettaEditor", dependencies: ["LunettaUI"]),
        .testTarget(name: "LunettaEditorTests", dependencies: ["LunettaEditor"]),
    ]
)
