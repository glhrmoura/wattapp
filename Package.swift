// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Watt",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Watt", path: "Sources/Watt")
    ]
)
