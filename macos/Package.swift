// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DipAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DipAgent", path: "Sources/DipAgent")
    ]
)
