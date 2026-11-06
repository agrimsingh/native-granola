import Foundation
import GranolaCore

public enum PostMeetingError: Error, CustomStringConvertible {
    case meetingNotFound
    case stillRecording

    public var description: String {
        switch self {
        case .meetingNotFound: "The meeting no longer exists"
        case .stillRecording: "The meeting is still being recorded"
        }
    }
}

/// Improves a finished meeting's transcript from its saved audio: optionally re-transcribes each source
/// with Parakeet, and labels remote speakers with diarization. The live transcript is kept for any
/// source whose audio is missing or fails to transcribe. Runs off the main thread; cancel the calling
/// task to stop (nothing is written once cancelled).
public struct PostMeetingProcessor: Sendable {
    public struct Options: Sendable {
        /// Re-transcribe with this model, or keep the live transcript when nil.
        public var retranscribeWith: ParakeetModel?
        public var separateSpeakers: Bool
        public var audioRoot: URL

        public init(retranscribeWith: ParakeetModel? = nil, separateSpeakers: Bool = true,
                    audioRoot: URL = AudioArchive.root) {
            self.retranscribeWith = retranscribeWith
            self.separateSpeakers = separateSpeakers
            self.audioRoot = audioRoot
        }
    }

    public enum Stage: Sendable, Equatable {
        case transcribing(TranscriptSource)
        case separatingSpeakers
    }

    public struct Outcome: Sendable {
        public var retranscribed: [TranscriptSource] = []
        public var droppedEchoes = 0
        /// Distinct remote speakers labelled; 0 when diarization didn't run or found only one.
        public var speakerCount = 0
        public var warnings: [String] = []
    }

    public let store: Store
    public var options: Options

    public init(store: Store, options: Options) {
        self.store = store
        self.options = options
    }

    public func run(meetingID: String, onStage: @Sendable (Stage) -> Void = { _ in }) async throws -> Outcome {
        guard let meeting = try store.meeting(id: meetingID) else { throw PostMeetingError.meetingNotFound }
        guard !meeting.isInProgress else { throw PostMeetingError.stillRecording }
        let live = try store.segments(meetingID: meetingID)
        var outcome = Outcome()

        var words: [TranscriptSource: [TimedWord]] = [:]
        if let model = options.retranscribeWith {
            let transcriber = ParakeetTranscriber(model: model)
            for source in TranscriptSource.allCases {
                let url = AudioArchive.url(meetingID: meetingID, source: source, root: options.audioRoot)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try Task.checkCancellation()
                onStage(.transcribing(source))
                do {
                    let result = try await transcriber.transcribe(url: url)
                    if result.words.isEmpty, live.contains(where: { $0.source == source }) {
                        outcome.warnings.append("Parakeet heard nothing in the \(source.rawValue) audio; kept the live transcript")
                        continue
                    }
                    words[source] = result.words
                } catch {
                    try Task.checkCancellation()
                    outcome.warnings.append("Re-transcribing \(source.rawValue) audio failed: \(error.localizedDescription)")
                }
            }
        }

        var turns: [SpeakerTurn]?
        let systemAudio = AudioArchive.url(meetingID: meetingID, source: .system, root: options.audioRoot)
        if options.separateSpeakers, words[.system] != nil || live.contains(where: { $0.source == .system }),
           FileManager.default.fileExists(atPath: systemAudio.path) {
            try Task.checkCancellation()
            onStage(.separatingSpeakers)
            do {
                turns = try await SpeakerDiarizer.turns(audioURL: systemAudio)
            } catch {
                try Task.checkCancellation()
                outcome.warnings.append("Speaker separation failed: \(error.localizedDescription)")
            }
        }

        var segments = live
        if !words.isEmpty {
            var rebuilt = live.filter { words[$0.source] == nil }
            for (source, w) in words {
                let speaker: ((TimedWord) -> String?)? = source == .system
                    ? turns.map { t in { SpeakerAssignment.speaker(of: $0, turns: t) } } : nil
                rebuilt += SegmentBuilder.segments(from: w, meetingID: meetingID, source: source, speaker: speaker)
            }
            rebuilt.sort { $0.startOffset < $1.startOffset }
            segments = Self.removingEchoes(rebuilt)
            outcome.droppedEchoes = rebuilt.count - segments.count
            outcome.retranscribed = TranscriptSource.allCases.filter { words[$0] != nil }
        }

        var labels: [String: String?]?
        if let turns {
            let assigned = SpeakerAssignment.labels(for: segments, turns: turns)
            labels = assigned
            outcome.speakerCount = Set(assigned.values.compactMap { $0 }).count
        }

        try Task.checkCancellation()
        guard try store.meeting(id: meetingID) != nil else { throw PostMeetingError.meetingNotFound }
        if !outcome.retranscribed.isEmpty {
            if let labels {
                for i in segments.indices { segments[i].speaker = labels[segments[i].id] ?? nil }
            }
            try store.replaceSegments(meetingID: meetingID, with: segments)
        } else if let labels {
            try store.setSpeakers(labels, meetingID: meetingID)
        }
        return outcome
    }

    /// Drops microphone segments that are the system audio picked up by the mic.
    static func removingEchoes(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let system = segments.filter { $0.source == .system }
        return segments.filter { s in
            s.source != .microphone || !system.contains { EchoFilter.isEcho(mic: s, system: $0) }
        }
    }
}
