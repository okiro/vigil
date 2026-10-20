// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Vigil",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Vigil",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
