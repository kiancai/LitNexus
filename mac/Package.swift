// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LitNexus",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "LitNexus",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/LitNexus"
        )
    ]
)
