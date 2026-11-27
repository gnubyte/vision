// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisionHarness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VisionHarnessCore", targets: ["VisionHarnessCore"]),
        .executable(name: "Vision", targets: ["VisionMacApp"]),
    ],
    targets: [
        // Agent engine: LLM clients, tool execution, permissions, sessions.
        // No UI, no AppKit — verifiable headlessly. The iPhone app (iOS/project.yml)
        // builds the platform-neutral part of this target's sources as well.
        .target(name: "VisionHarnessCore"),
        // The native SwiftUI app — it IS the harness.
        .executableTarget(name: "VisionMacApp", dependencies: ["VisionHarnessCore"]),
        // Engine tests (tools, permissions, Qwen XML parser, loop).
        .testTarget(name: "VisionHarnessCoreTests", dependencies: ["VisionHarnessCore"]),
        // The harness end to end: the task queue runner, /goal, retries —
        // driven against a fake model server.
        .testTarget(name: "VisionMacAppTests", dependencies: ["VisionMacApp", "VisionHarnessCore"]),
    ]
)