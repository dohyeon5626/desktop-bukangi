// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bukangi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bukangi",
            path: "Sources/Bukangi",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
