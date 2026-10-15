// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bukangi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bukangi",
            path: "Sources/Bukangi"
        )
    ],
    swiftLanguageModes: [.v5]
)
