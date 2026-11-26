// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunettaUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LunettaUI", targets: ["LunettaUI"])],
    targets: [
        .target(name: "LunettaUI"),
    ]
)
