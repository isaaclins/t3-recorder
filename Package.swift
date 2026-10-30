// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "T3Recorder",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet speech-to-text on the Neural Engine, same version as the Steward app. No traits: no text-to-speech front ends needed.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "RecorderCore", path: "Sources/RecorderCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "T3Recorder",
            dependencies: ["RecorderCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/T3Recorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"], path: "Tests/RecorderCoreTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
