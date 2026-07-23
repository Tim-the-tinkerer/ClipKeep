// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipKeep",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipKeep", targets: ["ClipKeep"]),
    ],
    targets: [
        .executableTarget(
            name: "ClipKeep",
            path: "Sources/ClipKeep"
        ),
    ]
)
