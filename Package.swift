// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Eavesdropper",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "EavesdropperCore"),
        .executableTarget(name: "Eavesdropper", dependencies: ["EavesdropperCore"]),
        .executableTarget(name: "DetectorChecks", dependencies: ["EavesdropperCore"]),
    ],
    swiftLanguageModes: [.v5]
)
