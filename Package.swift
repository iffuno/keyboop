// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Keyboop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Keyboop",
            path: "Sources/Keyboop",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
