// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Eavesdropper",
    platforms: [.macOS("26.0")],
    dependencies: [
        // On-device speaker diarization (Core ML), diarizer only.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "EavesdropperCore"),
        .executableTarget(name: "Eavesdropper", dependencies: [
            "EavesdropperCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "DetectorChecks", dependencies: ["EavesdropperCore"]),
    ],
    swiftLanguageModes: [.v5]
)
