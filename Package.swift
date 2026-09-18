// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic (project model, time mapping, springs, auto-zoom). No AppKit. Everything testable lives here.
        .target(name: "RecorderCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The app: AppKit shell, SwiftUI panels, capture, Metal compositor, export.
        .executableTarget(name: "Recorder", dependencies: ["RecorderCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
