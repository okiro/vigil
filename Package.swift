// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Vigil",
            path: "Sources/Vigil",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
