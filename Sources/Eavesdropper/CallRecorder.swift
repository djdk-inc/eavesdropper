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

/// AAC file settings matching `format`, so buffers can be written as they arrive.
private func aacFile(_ url: URL, _ format: AVAudioFormat) throws -> AVAudioFile {
    try AVAudioFile(
        forWriting: url,
        settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: min(format.channelCount, 2)],
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
}

/// Records one call into a folder: `mic.m4a` (your microphone) and `call.m4a`
/// (only the meeting app's sound, via a Core Audio process tap).
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
        let file = try aacFile(folder.appendingPathComponent("mic.m4a"), format)
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

        let file = try aacFile(folder.appendingPathComponent("call.m4a"), format)
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
