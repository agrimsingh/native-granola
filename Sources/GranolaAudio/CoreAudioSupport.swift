import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { (0x20...0x7E).contains($0) } ? " ('\(String(decoding: bytes, as: UTF8.self))')" : ""
        return "\(operation) failed: \(status)\(fourCC)"
    }
}

@discardableResult
func check(_ operation: String, _ status: OSStatus) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return status
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) throws -> T {
    var addr = address(selector, scope: scope)
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    try check("Get property \(selector)",
              AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier, &size, &result))
    return result
}

func getStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check("Get string property \(selector)", AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value))
    return value?.takeRetainedValue() as String? ?? ""
}

enum AudioSystem {
    static func defaultOutputDevice() throws -> AudioDeviceID {
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                        default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        try getStringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    /// The Core Audio process object for a PID, or nil if the process has never touched audio.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        let object = try? withUnsafePointer(to: &pid) { ptr in
            try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject,
                            default: AudioObjectID(kAudioObjectUnknown),
                            qualifier: ptr, qualifierSize: UInt32(MemoryLayout<pid_t>.size))
        }
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }
}
