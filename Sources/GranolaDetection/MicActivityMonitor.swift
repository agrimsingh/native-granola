import AppKit
import CoreAudio
import Darwin
import Foundation

/// One Core Audio process object, as read from the HAL.
public struct AudioProcessSnapshot: Sendable, Hashable {
    public var pid: Int32
    /// Empty/nil for unbundled processes.
    public var bundleID: String?
    /// Executable name (from `proc_name`), used when there's no bundle ID.
    public var processName: String?
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(pid: Int32, bundleID: String?, processName: String? = nil, isRunningInput: Bool, isRunningOutput: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.processName = processName
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Pure filtering/normalization of audio processes into user-facing mic apps.
public enum MicAppResolver {
    public static func resolve(
        _ processes: [AudioProcessSnapshot],
        ownPID: Int32,
        excludedBundleIDs: Set<String> = [],
        nameLookup: (_ bundleID: String, _ pid: Int32) -> String? = { _, _ in nil }
    ) -> [MicApp] {
        let excluded = Set(excludedBundleIDs.map { $0.lowercased() })
        var groups: [String: (pid: Int32, isParent: Bool)] = [:]
        for process in processes where process.isRunningInput && process.pid != ownPID {
            let raw = (process.bundleID?.isEmpty == false ? process.bundleID : process.processName) ?? ""
            guard !raw.isEmpty, !AppIdentity.isSystemService(raw) else { continue }
            let normalized = AppIdentity.normalizedBundleID(raw)
            guard !excluded.contains(raw.lowercased()), !excluded.contains(normalized.lowercased()) else { continue }
            let isParent = raw == normalized
            if let existing = groups[normalized], existing.isParent || !isParent { continue }
            groups[normalized] = (process.pid, isParent)
        }
        return groups.map { bundleID, entry in
            let name = AppIdentity.friendlyNames[bundleID] ?? nameLookup(bundleID, entry.pid) ?? bundleID
            return MicApp(bundleID: bundleID, name: name, pid: entry.pid)
        }
        .sorted { ($0.name.lowercased(), $0.bundleID) < ($1.name.lowercased(), $1.bundleID) }
    }
}

/// Polls Core Audio process objects (macOS 14.2+) for apps currently capturing microphone input.
/// Reading these properties needs no TCC permission.
public final class MicActivityMonitor: @unchecked Sendable {
    public let pollInterval: TimeInterval

    private let queue = DispatchQueue(label: "NativeGranola.MicActivityMonitor", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var current: [MicApp] = []
    private var hasPolled = false
    private var handler: (@Sendable ([MicApp]) -> Void)?
    private var continuations: [UUID: AsyncStream<[MicApp]>.Continuation] = [:]
    private var extraExclusions: Set<String>

    /// `excludedBundleIDs` are skipped in addition to our own PID, our own bundle ID and system services.
    public init(pollInterval: TimeInterval = 1.5, excludedBundleIDs: Set<String> = []) {
        self.pollInterval = pollInterval
        var excluded = excludedBundleIDs
        if let own = Bundle.main.bundleIdentifier { excluded.insert(own) }
        self.extraExclusions = excluded
    }

    deinit { timer?.cancel() }

    /// Called on a background queue with the full current list whenever it changes (and once after the first poll).
    public var onChange: (@Sendable ([MicApp]) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    public var currentApps: [MicApp] { lock.withLock { current } }

    public var isRunning: Bool { lock.withLock { timer != nil } }

    /// A stream of the current list; yields the latest value immediately if a poll has happened.
    public func updates() -> AsyncStream<[MicApp]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                if hasPolled { continuation.yield(current) }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            hasPolled = false
            current = []
        }
    }

    private func poll() {
        let apps = Self.currentMicApps(excludedBundleIDs: extraExclusions)
        let (changed, callback, sinks): (Bool, (@Sendable ([MicApp]) -> Void)?, [AsyncStream<[MicApp]>.Continuation]) = lock.withLock {
            guard timer != nil else { return (false, nil, []) }
            let changed = !hasPolled || apps != current
            hasPolled = true
            current = apps
            return (changed, handler, Array(continuations.values))
        }
        guard changed else { return }
        callback?(apps)
        sinks.forEach { $0.yield(apps) }
    }

    // MARK: - One-shot queries

    public static func currentMicApps(excludedBundleIDs: Set<String> = []) -> [MicApp] {
        MicAppResolver.resolve(
            audioProcesses(),
            ownPID: getpid(),
            excludedBundleIDs: excludedBundleIDs,
            nameLookup: runningAppName
        )
    }

    /// All Core Audio process objects with their input/output state.
    public static func audioProcesses() -> [AudioProcessSnapshot] {
        processObjectIDs().compactMap { object in
            guard let pid: pid_t = read(object, kAudioProcessPropertyPID) else { return nil }
            let input: UInt32 = read(object, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = read(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessSnapshot(
                pid: pid,
                bundleID: readString(object, kAudioProcessPropertyBundleID),
                processName: processName(pid),
                isRunningInput: input != 0,
                isRunningOutput: output != 0
            )
        }
    }

    private static func runningAppName(bundleID: String, pid: Int32) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value?.takeRetainedValue() as String? else { return nil }
        return string.isEmpty ? nil : string
    }
}
