import AVFAudio
import FluidAudio
import Foundation

public struct ParakeetResult: Sendable {
    public var text: String
    public var words: [TimedWord]
    /// Audio duration, seconds.
    public var duration: TimeInterval
    /// Inference time, seconds, excluding model loading.
    public var processingTime: TimeInterval
}

/// Batch transcription with NVIDIA Parakeet TDT through FluidAudio (Core ML, Apple Neural Engine).
/// Holds roughly 1 GB of models while loaded; drop the instance when done.
public actor ParakeetTranscriber {
    public let model: ParakeetModel
    private var manager: AsrManager?

    public init(model: ParakeetModel) {
        self.model = model
    }

    /// Downloads the model if needed and loads it. Returns the seconds spent.
    @discardableResult
    public func load(progress: ProgressHandler? = nil) async throws -> TimeInterval {
        if manager != nil { return 0 }
        let started = Date()
        let models = try await AsrModels.downloadAndLoad(version: model.version, progressHandler: progress)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return Date().timeIntervalSince(started)
    }

    public func transcribe(url: URL) async throws -> ParakeetResult {
        try await load()
        guard let manager else { throw ASRError.notInitialized }
        let duration = try Self.duration(of: url)
        // Parakeet rejects clips under 300 ms; there's nothing to transcribe in them anyway.
        guard duration >= 0.35 else { return ParakeetResult(text: "", words: [], duration: duration, processingTime: 0) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result = try await manager.transcribe(url, decoderState: &state)
        let elapsed = Date().timeIntervalSince(started)
        return ParakeetResult(text: result.text, words: Self.words(from: result), duration: duration,
                              processingTime: elapsed)
    }

    static func words(from result: ASRResult) -> [TimedWord] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TimedWord(text: text, start: 0, end: result.duration)]
        }
        return buildWordTimings(from: timings).map { TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
