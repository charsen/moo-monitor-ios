// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MooMonitor",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MooMonitor", targets: ["MooMonitor"]),
    ],
    targets: [
        .target(name: "MooMonitorCrash"),
        .target(name: "MooMonitor", dependencies: ["MooMonitorCrash"]),
        .executableTarget(name: "MonitorCrashProbe", dependencies: ["MooMonitorCrash"], path: "Tests/CrashProbe"),
        .testTarget(name: "MooMonitorTests", dependencies: ["MooMonitor"], resources: [.copy("Fixtures")]),
    ]
)
