// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DipAgent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../shared/DipAgentKit")
    ],
    targets: [
        .executableTarget(
            name: "DipAgent",
            dependencies: [.product(name: "DipAgentKit", package: "DipAgentKit")],
            path: "Sources/DipAgent"
        )
    ]
)
