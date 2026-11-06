import AVFAudio
import Foundation
import os

/// Captures the default input device. With voice processing on, Apple's echo canceller removes
/// what the speakers play from the mic signal, so other participants don't show up as "Me".
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    private let log = Logger(subsystem: "com.nativegranola", category: "microphone")
    private var engine = AVAudioEngine()
    private var handler: Handler?
    private var configObserver: NSObjectProtocol?
    public let voiceProcessing: Bool
    /// Whether echo cancellation is actually on; it's dropped when it can't start with the current devices.
    public private(set) var isVoiceProcessingActive = false

    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    deinit { stop() }

    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    public func start(handler: @escaping Handler) throws {
        self.handler = handler
        try startEngine()
        // Device changes (headphones plugged in, AirPods connecting) stop the engine.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as AnyObject?) === self.engine else { return }
            self.log.info("Audio configuration changed; restarting microphone")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            do { try self.startEngine() } catch { self.log.error("Mic restart failed: \(String(describing: error))") }
        }
    }

    public func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    private func startEngine() throws {
        guard let handler else { return }
        do {
            try startEngine(handler: handler, voiceProcessing: voiceProcessing)
        } catch where voiceProcessing {
            // Voice processing can fail to initialize with some device combinations (-10875).
            log.error("Microphone failed to start with voice processing, retrying without: \(String(describing: error))")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine = AVAudioEngine()
            try startEngine(handler: handler, voiceProcessing: false)
        }
    }

    private func startEngine(handler: @escaping Handler, voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                log.error("Voice processing unavailable, continuing without echo cancellation: \(String(describing: error))")
            }
        }
        // Don't touch mainMixerNode: wiring the output path makes the voice-processing unit fail to
        // initialize (-10875). An input tap alone is enough to run the engine.
        let format = input.outputFormat(forBus: 0)
        log.info("Microphone format: \(format, privacy: .public), voice processing: \(input.isVoiceProcessingEnabled)")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler(buffer.firstChannel() ?? buffer)
        }
        engine.prepare()
        try engine.start()
        isVoiceProcessingActive = input.isVoiceProcessingEnabled
    }
}

extension AVAudioPCMBuffer {
    /// Voice processing on macOS delivers the same processed signal on every channel (5 on a MacBook Pro).
    /// Returns channel 0 as a mono buffer, or nil if the buffer is already mono or not float.
    func firstChannel() -> AVAudioPCMBuffer? {
        guard format.channelCount > 1, let source = floatChannelData,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frameLength),
              let dest = copy.floatChannelData
        else { return nil }
        copy.frameLength = frameLength
        dest[0].update(from: source[0], count: Int(frameLength))
        return copy
    }
}
