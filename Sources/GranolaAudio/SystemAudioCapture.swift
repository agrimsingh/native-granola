import AVFAudio
import CoreAudio
import Foundation
import os

/// Captures what the Mac plays through a Core Audio process tap wrapped in a private aggregate device:
/// either every process except this one, or just one app's processes (including its helpers).
/// Requires the System Audio Recording permission (`NSAudioCaptureUsageDescription`); macOS prompts
/// on the first start.
public final class SystemAudioCapture: @unchecked Sendable {
    public typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    public enum Scope: Sendable, Equatable {
        case all
        /// Only the app with this bundle ID. Falls back to `.all` when its audio can't be isolated.
        case app(bundleID: String)
    }

    private let log = Logger(subsystem: "com.nativegranola", category: "system-audio")
    private let ioQueue = DispatchQueue(label: "com.nativegranola.system-audio.io", qos: .userInitiated)
    /// Rebuilds stop the IOProc and wait for it, so they must not run on `ioQueue`.
    private let controlQueue = DispatchQueue(label: "com.nativegranola.system-audio.control", qos: .userInitiated)
    private let lock = NSLock()
    private let onFallback: (@Sendable (AppTapMonitor.Reason) -> Void)?
    private var scope: Scope
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var handler: Handler?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var pollTimer: DispatchSourceTimer?
    private var tappedProcesses: [AudioObjectID] = []
    private var monitor = AppTapMonitor()
    private var startedAt = Date()

    public private(set) var format: AVAudioFormat?

    /// The scope in effect: `.all` after falling back from an app scope.
    public var activeScope: Scope { lock.withLock { scope } }

    /// `onFallback` is called (on a background queue) when an app scope gives way to capturing everything.
    public init(scope: Scope = .all, onFallback: (@Sendable (AppTapMonitor.Reason) -> Void)? = nil) {
        self.scope = scope
        self.onFallback = onFallback
    }

    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        startedAt = Date()
        monitor = AppTapMonitor()
        if case let .app(bundleID) = scope, AudioSystem.appPIDs(bundleID: bundleID).isEmpty,
           matchingProcesses(bundleID).isEmpty {
            fallBackLocked(.appNotFound)
        }
        do {
            try startLocked()
        } catch where scope != .all {
            log.error("App-scoped tap failed, capturing all audio: \(String(describing: error))")
            teardownLocked()
            fallBackLocked(.appNotFound)
            do { try startLocked() } catch {
                teardownLocked()
                throw error
            }
        } catch {
            teardownLocked()
            throw error
        }
        listenForOutputDeviceChanges()
        startPolling()
    }

    public func stop() {
        let listener: AudioObjectPropertyListenerBlock? = lock.withLock {
            handler = nil
            pollTimer?.cancel()
            pollTimer = nil
            defer { outputListener = nil }
            return outputListener
        }
        // Removing a listener waits for a running callback, which takes the lock.
        if let listener {
            var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, listener)
        }
        lock.withLock { teardownLocked() }
    }

    private func startLocked() throws {
        guard let handler else { return }
        let description = makeDescription()
        try check("Create process tap", AudioHardwareCreateProcessTap(description, &tapID))

        // The aggregate is clocked by the current output device; the tap gets drift compensation.
        let outputUID = try AudioSystem.deviceUID(AudioSystem.defaultOutputDevice())
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NativeGranola Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("Create aggregate device", AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID))

        var asbd = try getProperty(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        // The tap can report 48 kHz while the device runs slower (e.g. AirPods in a call drop to
        // 24 kHz); the device's nominal rate is the one the samples actually arrive at.
        let deviceRate = try getProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
        if deviceRate > 0 { asbd.mSampleRate = deviceRate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(operation: "Read tap format", status: kAudioHardwareUnsupportedOperationError)
        }
        self.format = format
        log.info("System tap started (\(String(describing: self.scope), privacy: .public), \(self.tappedProcesses.count) processes): \(format, privacy: .public) via output \(outputUID, privacy: .public)")

        try check("Create IOProc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            guard let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  view.frameLength > 0, let copy = view.deepCopy() else { return }
            handler(copy)
        })
        try check("Start aggregate device", AudioDeviceStart(aggregateID, procID))
    }

    private func makeDescription() -> CATapDescription {
        let description: CATapDescription
        switch scope {
        case .all:
            let excluded = AudioSystem.processObject(pid: getpid()).map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            tappedProcesses = []
        case let .app(bundleID):
            let processes = matchingProcesses(bundleID)
            tappedProcesses = processes.map(\.objectID).sorted()
            description = CATapDescription(monoMixdownOfProcesses: tappedProcesses)
            description.bundleIDs = Array(Set(processes.compactMap(\.bundleID) + [bundleID])).sorted()
            description.isProcessRestoreEnabled = true
        }
        description.uuid = tapUUID
        description.name = "NativeGranola System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func matchingProcesses(_ bundleID: String) -> [AudioClientProcess] {
        let pids = AudioSystem.appPIDs(bundleID: bundleID)
        return AudioSystem.clientProcesses().filter { AppAudioMatcher.matches($0, target: bundleID, appPIDs: pids) }
    }

    private func teardownLocked() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func restartLocked() {
        teardownLocked()
        do { try startLocked() } catch { log.error("Restart failed: \(String(describing: error))") }
    }

    private func fallBackLocked(_ reason: AppTapMonitor.Reason) {
        guard case let .app(bundleID) = scope else { return }
        log.info("Falling back to all system audio (\(bundleID, privacy: .public): \(String(describing: reason), privacy: .public))")
        scope = .all
        if let onFallback { DispatchQueue.global().async { onFallback(reason) } }
    }

    /// In app scope, follows the app's processes as they come and go (a call often starts a new
    /// helper) and decides whether to fall back.
    private func startPolling() {
        guard pollTimer == nil, case .app = scope else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        lock.lock()
        defer { lock.unlock() }
        guard handler != nil, case let .app(bundleID) = scope else {
            pollTimer?.cancel()
            pollTimer = nil
            return
        }
        let pids = AudioSystem.appPIDs(bundleID: bundleID)
        let all = AudioSystem.clientProcesses()
        let matched = all.filter { AppAudioMatcher.matches($0, target: bundleID, appPIDs: pids) }
        let ids = matched.map(\.objectID).sorted()
        if ids != tappedProcesses, tapID != kAudioObjectUnknown {
            log.info("\(bundleID, privacy: .public) audio processes changed: \(ids.count) now")
            do {
                try AudioHardwareTap(id: tapID).setDescription(makeDescription())
            } catch {
                log.error("Updating tap failed, rebuilding: \(String(describing: error))")
                restartLocked()
            }
        }
        let verdict = monitor.observe(
            at: Date().timeIntervalSince(startedAt), matched: matched.count,
            targetPlaying: matched.contains { $0.isRunningOutput },
            othersPlaying: all.contains { $0.isRunningOutput && !ids.contains($0.objectID) })
        if case let .fallBack(reason) = verdict {
            fallBackLocked(reason)
            restartLocked()
        }
    }

    /// Rebuild the tap when the output device changes (e.g. AirPods connect), since the aggregate
    /// device is clocked by it.
    private func listenForOutputDeviceChanges() {
        guard outputListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.handler != nil else { return }
            self.log.info("Default output device changed; restarting system tap")
            self.restartLocked()
        }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, listener) == noErr {
            outputListener = listener
        }
    }
}

extension AVAudioPCMBuffer {
    /// Copies the samples out of a buffer whose memory is only valid for the duration of a callback.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }

    /// Root-mean-square level of the first channel, 0...1.
    public var rmsLevel: Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<Int(frameLength) { sum += samples[i] * samples[i] }
        return (sum / Float(frameLength)).squareRoot()
    }
}
