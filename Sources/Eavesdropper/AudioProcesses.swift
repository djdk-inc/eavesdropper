import CoreAudio
import EavesdropperCore
import Foundation

/// Reads a fixed-size Core Audio property.
func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
    return status == noErr ? result : value
}

func audioStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

/// Every process Core Audio knows about, with whether it is recording or playing right now.
func audioProcesses() -> [AudioProcess] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

    return ids.map { id in
        AudioProcess(
            objectID: id,
            pid: audioProperty(id, kAudioProcessPropertyPID, default: pid_t(-1)),
            bundleID: audioStringProperty(id, kAudioProcessPropertyBundleID) ?? "",
            isRunningInput: audioProperty(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
            isRunningOutput: audioProperty(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
        )
    }
}
