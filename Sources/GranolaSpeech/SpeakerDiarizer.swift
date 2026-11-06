import FluidAudio
import Foundation

/// Offline speaker diarization (pyannote segmentation + WeSpeaker embeddings + VBx clustering) via FluidAudio.
public enum SpeakerDiarizer {
    public static func turns(audioURL: URL) async throws -> [SpeakerTurn] {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        try Task.checkCancellation()
        let result = try await manager.process(audioURL)
        return result.segments
            .map { SpeakerTurn(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }
}
