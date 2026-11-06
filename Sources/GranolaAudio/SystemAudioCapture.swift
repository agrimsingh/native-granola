import AVFAudio
import CoreAudio
import Foundation
import os

/// Captures everything the Mac plays (every process except this one) through a Core Audio process
/// tap wrapped in a private aggregate device. Requires macOS 14.2+ and the System Audio Recording
/// permission (`NSAudioCaptureUsageDescription`); macOS prompts on the first start.
public final class SystemAudioCapture: @unchecked Sendable {
    public typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    private let log = Logger(subsystem: "com.nativegranola", category: "system-audio")
    private let ioQueue = DispatchQueue(label: "com.nativegranola.system-audio.io", qos: .userInitiated)
    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var handler: Handler?
    private var outputListener: AudioObjectPropertyListenerBlock?

    public private(set) var format: AVAudioFormat?

    public init() {}

    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        do {
            try startLocked()
        } catch {
            teardownLocked()
            throw error
        }
        listenForOutputDeviceChanges()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let outputListener {
            var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, ioQueue, outputListener)
            self.outputListener = nil
        }
        teardownLocked()
        handler = nil
    }

    private func startLocked() throws {
        guard let handler else { return }
        let excluded = AudioSystem.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "NativeGranola System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
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
        log.info("System tap started: \(format, privacy: .public) via output \(outputUID, privacy: .public)")

        try check("Create IOProc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            guard let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  view.frameLength > 0, let copy = view.deepCopy() else { return }
            handler(copy)
        })
        try check("Start aggregate device", AudioDeviceStart(aggregateID, procID))
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
            self.teardownLocked()
            do { try self.startLocked() } catch { self.log.error("Restart failed: \(String(describing: error))") }
        }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, ioQueue, listener) == noErr {
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
