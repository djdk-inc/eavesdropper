import AVFoundation
import EavesdropperCore
import Speech

/// Transcribes an audio file on-device with Apple's SpeechTranscriber; nothing leaves the Mac.
func transcribe(_ file: URL, speaker: String) async throws -> [TranscriptLine] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        log("downloading speech model for \(locale.identifier)")
        try await install.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collect = Task {
        var lines = [TranscriptLine]()
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(TranscriptLine(start: result.range.start.seconds, speaker: speaker, text: text)) }
        }
        return lines
    }
    let audio = try AVAudioFile(forReading: file)
    if let end = try await analyzer.analyzeSequence(from: audio) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collect.value
}
