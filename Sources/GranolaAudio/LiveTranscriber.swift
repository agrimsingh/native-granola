import AVFAudio
import CoreMedia
import Foundation
import GranolaCore
import os
import Speech

public struct TranscriptUpdate: Sendable, Equatable {
    public var source: TranscriptSource
    public var text: String
    /// Seconds since the recording session started.
    public var start: TimeInterval
    public var end: TimeInterval
    public var isFinal: Bool
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case noCompatibleAudioFormat

    public var description: String {
        switch self {
        case let .unsupportedLocale(id): "On-device transcription doesn't support \(id)"
        case .noCompatibleAudioFormat: "No audio format compatible with the speech model"
        }
    }
}

/// Streams one audio source through Apple's on-device SpeechTranscriber (macOS 26).
public final class LiveTranscriber: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable (TranscriptUpdate) -> Void

    private let log = Logger(subsystem: "com.nativegranola", category: "transcriber")
    private let source: TranscriptSource
    private let sessionStart: Date
    private let onUpdate: UpdateHandler
    private let lock = NSLock()

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: BufferConverter?
    /// Offset of this stream's first sample from `sessionStart`.
    private var streamOffset: TimeInterval?
    /// Session offset where the audio fed so far ends.
    private var fedEnd: TimeInterval = 0

    /// Gaps longer than this are filled with silence so the analyzer's clock keeps matching the session's.
    private static let minGap: TimeInterval = 0.25
    /// Longer gaps are marked with an explicit start time instead of feeding that much silence.
    private static let maxSilenceFill: TimeInterval = 30

    public init(source: TranscriptSource, sessionStart: Date, onUpdate: @escaping UpdateHandler) {
        self.source = source
        self.sessionStart = sessionStart
        self.onUpdate = onUpdate
    }

    /// Resolves the locale and downloads the on-device model if needed.
    public static func prepare(locale: Locale = .current) async throws -> Locale {
        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if resolved == nil { resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let supported = resolved else { throw TranscriberError.unsupportedLocale(locale.identifier) }
        let module = makeModule(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        return supported
    }

    private static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    public func start(locale: Locale, contextualStrings: [String] = []) async throws {
        let module = Self.makeModule(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.noCompatibleAudioFormat
        }
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let source = source, onUpdate = onUpdate, log = log
        let task = Task { [weak self] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let offset = self?.currentOffset ?? 0
                    let start = result.range.start.seconds, duration = result.range.duration.seconds
                    onUpdate(TranscriptUpdate(
                        source: source, text: text,
                        start: offset + (start.isFinite ? start : 0),
                        end: offset + (start.isFinite ? start : 0) + (duration.isFinite ? duration : 0),
                        isFinal: result.isFinal))
                }
            } catch {
                log.error("\(source.rawValue) transcription ended with error: \(String(describing: error))")
            }
        }

        lock.withLock {
            self.analyzer = analyzer
            self.continuation = continuation
            self.converter = BufferConverter(format: format)
            self.resultsTask = task
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        log.info("\(source.rawValue) transcriber started (\(locale.identifier), \(format))")
    }

    private var currentOffset: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return streamOffset ?? 0
    }

    /// Feed captured audio that starts `offset` seconds into the session. Safe to call from any
    /// thread; converts to the model's format.
    public func append(_ buffer: AVAudioPCMBuffer, at offset: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let converter, let converted = converter.convert(buffer) else { return }
        let rate = converter.format.sampleRate
        if streamOffset == nil {
            streamOffset = offset
            fedEnd = offset
        }
        let gap = offset - fedEnd
        var startTime: CMTime?
        if gap > Self.minGap {
            if gap <= Self.maxSilenceFill {
                var remaining = AVAudioFrameCount((gap * rate).rounded())
                while remaining > 0 {
                    let frames = min(remaining, AVAudioFrameCount(rate))
                    if let silence = AVAudioPCMBuffer.silence(format: converter.format, frames: frames) {
                        continuation.yield(AnalyzerInput(buffer: silence))
                    }
                    remaining -= frames
                }
            } else {
                startTime = CMTime(seconds: offset - (streamOffset ?? offset), preferredTimescale: CMTimeScale(rate))
            }
            fedEnd = offset
        }
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
        fedEnd += Double(converted.frameLength) / rate
    }

    /// Flushes pending audio so the last words are finalized, then shuts the analyzer down.
    public func finish() async {
        let (analyzer, continuation, task) = lock.withLock {
            let captured = (self.analyzer, self.continuation, self.resultsTask)
            self.continuation = nil
            return captured
        }
        continuation?.finish()
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch {
            log.error("Finalize failed: \(String(describing: error))")
        }
        await task?.value
    }
}

/// Batch transcription of an audio file with the same model, used by the self-test harness.
public enum FileTranscriber {
    public static func transcribe(url: URL, locale: Locale) async throws -> [TranscriptUpdate] {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module])
        let collect = Task {
            var out: [TranscriptUpdate] = []
            for try await r in module.results {
                out.append(TranscriptUpdate(source: .system, text: String(r.text.characters),
                                            start: r.range.start.seconds, end: r.range.end.seconds, isFinal: true))
            }
            return out
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }
}
