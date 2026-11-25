// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Eavesdropper",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "EavesdropperCore"),
        // The recorder: runs in the App Sandbox with no network access (Eavesdropper.entitlements).
        .executableTarget(name: "Eavesdropper", dependencies: ["EavesdropperCore", "FluidAudio"]),
        // The calendar helper: the only networked part; handles invite metadata only.
        .executableTarget(name: "EavesdropperCalendar", dependencies: ["EavesdropperCore"]),
        .executableTarget(name: "DetectorChecks", dependencies: ["EavesdropperCore"]),

        // Speaker diarization, copied from FluidAudio v0.18.4 (Apache-2.0; see Vendor/FluidAudio/NOTICE).
        // Only the diarizer and the shared code it needs; nothing is fetched at build time.
        .target(
            name: "FluidAudio",
            dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
            path: "Vendor/FluidAudio/Sources/FluidAudio",
            swiftSettings: [.define("Diarizer")]
        ),
        .target(name: "FastClusterWrapper", path: "Vendor/FluidAudio/Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "Vendor/FluidAudio/Sources/MachTaskSelfWrapper", publicHeadersPath: "include"),
    ],
    swiftLanguageModes: [.v5]
)
