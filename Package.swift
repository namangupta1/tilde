// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tilde",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Tilde",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Tilde",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Keeps shells running after the app quits; bundled next to the app binary.
        .executableTarget(
            name: "tilde-session",
            path: "Sources/tilde-session"
        ),
        .testTarget(
            name: "TildeTests",
            dependencies: ["Tilde"],
            path: "Tests/TildeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
