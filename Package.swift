// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsage",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .executable(name: "CodexUsageApp", targets: ["CodexUsageApp"]),
        .executable(name: "codex-meter-agent", targets: ["CodexMeterAgentCLI"]),
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(name: "CodexUsageApp", dependencies: ["CodexUsageCore"]),
        .executableTarget(name: "CodexMeterAgentCLI", dependencies: ["CodexUsageCore"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"]),
    ]
)
