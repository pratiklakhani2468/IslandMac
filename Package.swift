// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IslandMac",
    platforms: [.macOS(.v14)],
    targets: [
        // macOS's own zlib, for deflating PNGs at the maximum level (ImageIO can't be told to).
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(
            name: "IslandMac",
            dependencies: ["CZlib"],
            path: "Sources/IslandMac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
