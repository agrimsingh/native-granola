// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NativeGranola",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NativeGranola", targets: ["NativeGranola"]),
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
        .executableTarget(
            name: "NativeGranola",
            dependencies: [
                "GranolaCore", "GranolaAudio", "GranolaMCP",
                "GranolaIntelligence", "GranolaDetection",
            ]
        ),
        .testTarget(name: "GranolaCoreTests", dependencies: ["GranolaCore"]),
        .testTarget(name: "GranolaMCPTests", dependencies: ["GranolaMCP"]),
        .testTarget(name: "GranolaIntelligenceTests", dependencies: ["GranolaIntelligence"]),
        .testTarget(name: "GranolaDetectionTests", dependencies: ["GranolaDetection"]),
    ],
    swiftLanguageModes: [.v5]
)
