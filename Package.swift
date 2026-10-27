// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeProfileSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that can be tested without a menu bar: profiles, processes, links,
        // chat transfer, icons and launcher apps.
        .target(name: "SwitcherCore"),
        // The menu bar app and the command line, in one binary.
        .executableTarget(name: "ClaudeProfileSwitcher", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"]),
    ]
)
