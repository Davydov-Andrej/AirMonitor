// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirMonitor",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "yaCore", targets: ["yaCore"]),
        .library(name: "uaDSP", targets: ["uaDSP"]),
        .executable(name: "air-monitor", targets: ["air-monitor"]),
        .executable(name: "air-aio", targets: ["air-aio"]),
        .executable(name: "dspcheck", targets: ["dspcheck"])
    ],
    targets: [
        .target(
            name: "yaCore",
            dependencies: ["uaDSP"]
        ),
        .target(
            name: "uaDSP"
        ),
        .executableTarget(
            name: "dspcheck",
            dependencies: ["uaDSP"]
        ),
        .executableTarget(
            name: "air-monitor",
            dependencies: ["yaCore", "uaDSP"]
        ),
        .executableTarget(
            name: "air-aio",
            dependencies: ["yaCore"]
        )
    ]
)
