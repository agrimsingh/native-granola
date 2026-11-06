import AppKit
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

    /// Every process connected to Core Audio, except `excluded`.
    static func clientProcesses(excluding excluded: pid_t = getpid()) -> [AudioClientProcess] {
        let processes = (try? AudioHardwareSystem.shared.processes) ?? []
        return processes.compactMap { process in
            guard let pid = try? process.pid, pid != excluded else { return nil }
            let responsible = responsiblePID(pid)
            return AudioClientProcess(
                objectID: process.id, pid: pid, bundleID: (try? process.bundleID) ?? nil,
                responsiblePID: responsible == pid ? nil : responsible, parentPID: parentPID(pid),
                isRunningOutput: (try? process.isRunningOutput) ?? false)
        }
    }

    /// PIDs of the running instances of an app.
    static func appPIDs(bundleID: String) -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        return responsible > 0 ? responsible : nil
    }
}

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t
