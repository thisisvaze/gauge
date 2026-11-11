// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Gauge", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "GaugeTests", dependencies: ["Gauge"], swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
