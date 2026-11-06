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
        var segments = live

        if let model = options.retranscribeWith {
            let transcriber = ParakeetTranscriber(model: model)
            var replaced: [TranscriptSource: [TranscriptSegment]] = [:]
            for source in TranscriptSource.allCases {
                let url = AudioArchive.url(meetingID: meetingID, source: source, root: options.audioRoot)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try Task.checkCancellation()
                onStage(.transcribing(source))
                do {
                    let result = try await transcriber.transcribe(url: url)
                    let new = SegmentBuilder.segments(from: result.words, meetingID: meetingID, source: source)
                    if new.isEmpty, live.contains(where: { $0.source == source }) {
                        outcome.warnings.append("Parakeet heard nothing in the \(source.rawValue) audio; kept the live transcript")
                        continue
                    }
                    replaced[source] = new
                } catch {
                    try Task.checkCancellation()
                    outcome.warnings.append("Re-transcribing \(source.rawValue) audio failed: \(error)")
                }
            }
            if !replaced.isEmpty {
                segments = live.filter { replaced[$0.source] == nil } + replaced.values.joined()
                segments.sort { $0.startOffset < $1.startOffset }
                outcome.retranscribed = TranscriptSource.allCases.filter { replaced[$0] != nil }
                let before = segments.count
                segments = Self.removingEchoes(segments)
                outcome.droppedEchoes = before - segments.count
            }
        }

        var labels: [String: String?]?
        let systemAudio = AudioArchive.url(meetingID: meetingID, source: .system, root: options.audioRoot)
        if options.separateSpeakers, segments.contains(where: { $0.source == .system }),
           FileManager.default.fileExists(atPath: systemAudio.path) {
            try Task.checkCancellation()
            onStage(.separatingSpeakers)
            do {
                let turns = try await SpeakerDiarizer.turns(audioURL: systemAudio)
                let assigned = SpeakerAssignment.labels(for: segments, turns: turns)
                labels = assigned
                outcome.speakerCount = Set(assigned.values.compactMap { $0 }).count
            } catch {
                try Task.checkCancellation()
                outcome.warnings.append("Speaker separation failed: \(error)")
            }
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
