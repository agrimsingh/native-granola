// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NativeGranola",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NativeGranola", targets: ["NativeGranola"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2"),
    ],
    targets: [
        .target(
            name: "GranolaCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "GranolaAudio", dependencies: ["GranolaCore"]),
        .target(name: "GranolaMCP", dependencies: ["GranolaCore"]),
        .target(name: "GranolaIntelligence", dependencies: ["GranolaCore"]),
        .target(name: "GranolaDetection", dependencies: ["GranolaCore"]),
        .target(
            name: "GranolaSpeech",
            dependencies: ["GranolaCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "NativeGranola",
            dependencies: [
                "GranolaCore", "GranolaAudio", "GranolaMCP",
                "GranolaIntelligence", "GranolaDetection", "GranolaSpeech",
            ]
        ),
        .testTarget(name: "GranolaCoreTests", dependencies: ["GranolaCore"]),
        .testTarget(name: "GranolaMCPTests", dependencies: ["GranolaMCP"]),
        .testTarget(name: "GranolaIntelligenceTests", dependencies: ["GranolaIntelligence"]),
        .testTarget(name: "GranolaDetectionTests", dependencies: ["GranolaDetection"]),
        .testTarget(name: "GranolaSpeechTests", dependencies: ["GranolaSpeech"]),
        .testTarget(name: "GranolaAudioTests", dependencies: ["GranolaAudio"]),
    ],
    swiftLanguageModes: [.v5]
)
