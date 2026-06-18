// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LitNexus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LitNexus",
            path: "Sources/LitNexus"
        )
    ]
)
