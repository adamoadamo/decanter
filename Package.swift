// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Decanter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Decanter", path: "Sources/Decanter")
    ]
)
