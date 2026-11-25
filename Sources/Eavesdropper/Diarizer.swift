import EavesdropperCore
import FluidAudio
import Foundation

/// The diarizer model, copied into Eavesdropper.app by build-app.sh from the repo's Models/ folder.
/// Nothing is ever downloaded; outside the app bundle, diarization is unavailable and lines stay "Others".
var bundledDiarizerModels: URL? {
    let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/DiarizerModels", isDirectory: true)
    return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
}

/// Who spoke when in an audio file, on-device.
func speakerTurns(in file: URL, models: URL? = bundledDiarizerModels) async throws -> [SpeakerTurn] {
    let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    try await manager.prepareModels(directory: models)
    let result = try await manager.process(file)
    return result.segments.map {
        SpeakerTurn(start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds), voice: $0.speakerId)
    }
}

/// Transcribes the call's audio and labels each line by voice. If diarization fails, lines stay "Others".
func transcribeCall(_ file: URL) async throws -> [TranscriptLine] {
    let lines = try await transcribe(file, speaker: "Others")
    guard !lines.isEmpty else { return lines }
    do {
        let turns = try await speakerTurns(in: file)
        log("diarization: \(Set(turns.map(\.voice)).count) voices in \(turns.count) turns")
        return labelSpeakers(lines, turns: turns)
    } catch {
        log("diarization failed, keeping \"Others\": \(error)")
        return lines
    }
}
