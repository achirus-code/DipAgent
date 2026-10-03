// swift-tools-version:5.10
import PackageDescription

// What the macOS and the iPhone app share: models, the agent API client, the store (polling, actions,
// notifications) and the building blocks that look the same on both. Texts are looked up in the app's own
// bundle (shared/Localization), so the package has no resources of its own.
let package = Package(
    name: "DipAgentKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DipAgentKit", targets: ["DipAgentKit"])
    ],
    targets: [
        .target(name: "DipAgentKit", path: "Sources/DipAgentKit")
    ]
)
