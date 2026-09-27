// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PinBox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PinBox",
            path: "Sources/PinBox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
