import AVFoundation
import CoreAudio
import EavesdropperCore

enum RecorderError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    var description: String {
        switch self { case let .coreAudio(step, status): "\(step) failed (OSStatus \(status))" }
    }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw RecorderError.coreAudio(step, status) }
}

/// An uncompressed CAF file matching `format`. Unlike .m4a, CAF stays readable if the app is killed
/// mid-recording (a measured hard kill kept 2.8 of 3 s), so a crash or update never loses a call.
/// It's compressed to .m4a after transcription (compressRecording).
private func crashSafeFile(_ url: URL, _ format: AVAudioFormat) throws -> AVAudioFile {
    try AVAudioFile(
        forWriting: url,
        settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                   AVNumberOfChannelsKey: min(format.channelCount, 2),
                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
}

/// An audio file kept on the wall clock: each buffer's host time says where it belongs, and frames the
/// device skipped are written as silence (silenceToInsert). Used from one audio thread at a time.
final class TimelineFile {
    private let file: AVAudioFile
    private let origin: UInt64
    private var written: Int64 = 0
    private(set) var silence: Int64 = 0

    init(_ file: AVAudioFile, origin: UInt64) {
        self.file = file
        self.origin = origin
    }

    var sampleRate: Double { file.processingFormat.sampleRate }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) throws {
        if let hostTime, hostTime > origin {
            let elapsed = Double(AudioConvertHostTimeToNanos(hostTime - origin)) / 1e9
            let gap = silenceToInsert(written: written, elapsed: elapsed, sampleRate: sampleRate)
            if gap > 0 { try writeSilence(gap) }
        }
        try file.write(from: buffer)
        written += Int64(buffer.frameLength)
    }

    private func writeSilence(_ frames: Int64) throws {
        let chunk = AVAudioFrameCount(sampleRate) // one second at a time
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        var left = frames
        while left > 0 {
            buffer.frameLength = AVAudioFrameCount(min(Int64(chunk), left))
            for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
            try file.write(from: buffer)
            left -= Int64(buffer.frameLength)
        }
        written += frames
        silence += frames
    }
}

/// Records one call into a folder: `mic.caf` (your microphone) and `call.caf`
/// (the meeting app's sound, or everything the Mac plays for a manual recording).
/// Both files start at the same moment and stay on the wall clock, so the two sides line up.
final class CallRecorder {
    let folder: URL
    private let engine = AVAudioEngine()
    private let origin = AudioGetCurrentHostTime()
    private var micFile: TimelineFile?
    private var callFile: TimelineFile?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "eavesdropper.call-audio")

    init(call: Call, folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try startCallAudio(call)
        } catch {
            log("call audio not recorded: \(error)")
        }
        do {
            try startMic()
        } catch {
            log("mic not recorded: \(error)")
        }
    }

    private func startMic() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = TimelineFile(try crashSafeFile(folder.appendingPathComponent("mic.caf"), format), origin: origin)
        micFile = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            do { try file.write(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil) } catch { log("mic write: \(error)") }
        }
        try engine.start()
    }

    /// A call app's own sound, or for a manual recording everything the Mac plays (minus Eavesdropper).
    private func startCallAudio(_ call: Call) throws {
        let description: CATapDescription
        if call.app == .manual {
            let ownProcess = audioProcesses().filter { $0.pid == getpid() }.map(\.objectID)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: call.processObjectIDs)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd = audioProperty(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError.coreAudio("tap format", -1) }

        let outputDevice = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        guard let outputUID = audioStringProperty(outputDevice, kAudioDevicePropertyDeviceUID) else { throw RecorderError.coreAudio("output device UID", -1) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Eavesdropper Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        let file = TimelineFile(try crashSafeFile(folder.appendingPathComponent("call.caf"), format), origin: origin)
        callFile = file
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
            do { try file.write(buffer, hostTime: hostTime) } catch { log("call write: \(error)") }
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        queue.sync {} // drain pending writes before closing the file
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        for (name, file) in [("mic", micFile), ("call", callFile)] {
            if let file, file.silence > 0 { log("\(name): filled \(String(format: "%.1f", Double(file.silence) / file.sampleRate)) s the device skipped") }
        }
        micFile = nil // AVAudioFile finalizes on release
        callFile = nil
    }
}
