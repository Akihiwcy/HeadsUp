// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HeadsUp",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HeadsUp", targets: ["HeadsUp"]),
    ],
    targets: [
        .target(name: "HeadsUpCore"),
        .executableTarget(name: "HeadsUp", dependencies: ["HeadsUpCore"]),
        .testTarget(name: "HeadsUpCoreTests", dependencies: ["HeadsUpCore"]),
    ]
)
