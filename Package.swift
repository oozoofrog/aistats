// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "aistats", targets: ["aistats"]),
        .executable(name: "AIStatsMenu", targets: ["AIStatsMenu"]),
    ],
    targets: [
        .target(name: "StatsCore"),
        .executableTarget(name: "aistats", dependencies: ["StatsCore"]),
        .executableTarget(name: "AIStatsMenu", dependencies: ["StatsCore"]),
        .testTarget(name: "StatsCoreTests", dependencies: ["StatsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
