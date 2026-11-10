// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "wattapp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "wattapp", path: "Sources/wattapp")
    ]
)
