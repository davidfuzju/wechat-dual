// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WeChatDuo",
    platforms: [.macOS(.v14)],
    targets: [
        // All the logic: create, rename, recolor, sign, health check, auto-repair. No UI; testable and usable from the CLI.
        .target(name: "DuoCore"),
        // The menu bar app (SwiftUI MenuBarExtra) plus the `--cli` entry point.
        .executableTarget(name: "WeChatDuo", dependencies: ["DuoCore"]),
        .testTarget(name: "DuoCoreTests", dependencies: ["DuoCore"]),
    ]
)
