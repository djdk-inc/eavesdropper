import AVFoundation
import EavesdropperCore

/// One side of a meeting's audio ("mic" or "call"): the crash-safe .caf while recording and until it
/// has been compressed, then the .m4a.
func recordingFile(_ folder: URL, _ side: String) -> URL {
    let caf = folder.appendingPathComponent("\(side).caf")
    return FileManager.default.fileExists(atPath: caf.path) ? caf : folder.appendingPathComponent("\(side).m4a")
}

/// Compresses `<side>.caf` to `<side>.m4a` (AAC) and deletes the .caf once the copy reads back
/// at full length. If interrupted, the .caf stays and the next run tries again.
func compressRecording(_ folder: URL, _ side: String) throws {
    let caf = folder.appendingPathComponent("\(side).caf")
    let m4a = folder.appendingPathComponent("\(side).m4a")
    guard FileManager.default.fileExists(atPath: caf.path) else { return }
    let input = try AVAudioFile(forReading: caf)
    let format = input.processingFormat
    do {
        let output = try AVAudioFile(
            forWriting: m4a,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    } // output closes (and finalizes) here
    let written = try AVAudioFile(forReading: m4a)
    let seconds = { (f: AVAudioFile) in Double(f.length) / f.fileFormat.sampleRate }
    guard abs(seconds(written) - seconds(input)) < 1 else {
        throw RecorderError.coreAudio("compressing \(side) (\(seconds(written)) s of \(seconds(input)) s)", -1)
    }
    try FileManager.default.removeItem(at: caf)
}

/// When a meeting's audio was last written, for meetings cut off before they could note their end.
func lastWritten(_ folder: URL) -> Date? {
    ["mic", "call"].compactMap { side in
        (try? FileManager.default.attributesOfItem(atPath: recordingFile(folder, side).path))?[.modificationDate] as? Date
    }.max()
}
