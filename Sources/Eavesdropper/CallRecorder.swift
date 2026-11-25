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

/// Records one call into a folder: `mic.caf` (your microphone) and `call.caf`
/// (the meeting app's sound, or everything the Mac plays for a manual recording).
final class CallRecorder {
    let folder: URL
    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var callFile: AVAudioFile?
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
        let file = try crashSafeFile(folder.appendingPathComponent("mic.caf"), format)
        micFile = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do { try file.write(from: buffer) } catch { log("mic write: \(error)") }
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

        let file = try crashSafeFile(folder.appendingPathComponent("call.caf"), format)
        callFile = file
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            do { try file.write(from: buffer) } catch { log("call write: \(error)") }
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
        micFile = nil // AVAudioFile finalizes on release
        callFile = nil
    }
}
