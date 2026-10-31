// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CustomNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CustomNotch", path: "Sources/CustomNotch")
    ]
)
