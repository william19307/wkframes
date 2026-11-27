// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wkframes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "wkframes", path: "Sources/wkframes"),
    ]
)
