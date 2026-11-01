// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionMover",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionMoverKit", targets: ["SessionMoverKit"]),
        .executable(name: "smctl", targets: ["smctl"]),
        .executable(name: "SessionMover", targets: ["SessionMover"]),
    ],
    targets: [
        .target(name: "SessionMoverKit", resources: [.copy("Resources/verified-versions.json")]),
        .executableTarget(name: "smctl", dependencies: ["SessionMoverKit"]),
        .executableTarget(name: "SessionMover", dependencies: ["SessionMoverKit"]),
        .testTarget(name: "SessionMoverKitTests", dependencies: ["SessionMoverKit"]),
    ]
)
