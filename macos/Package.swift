// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Minutes",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Minutes",
            path: "Sources/Minutes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MinutesTests",
            dependencies: ["Minutes"],
            path: "Tests/MinutesTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
