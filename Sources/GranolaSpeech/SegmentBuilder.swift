import Foundation
import GranolaCore

/// A recognized word with times in seconds from the start of its audio file.
public struct TimedWord: Sendable, Hashable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Groups words into transcript segments the way people read a transcript: a new segment after a
/// pause, at the end of a sentence, or when a segment would run too long.
public enum SegmentBuilder {
    public struct Options: Sendable {
        public var pause: TimeInterval = 0.8
        public var maxDuration: TimeInterval = 20
        /// Sentence ends only split once a segment is at least this long, so "Yes." "Okay." stay together.
        public var minSentenceDuration: TimeInterval = 1.5

        public init() {}
    }

    /// `speaker` (from diarization) also starts a new segment whenever the speaker changes.
    public static func segments(from words: [TimedWord], meetingID: String, source: TranscriptSource,
                                options: Options = Options(),
                                speaker: ((TimedWord) -> String?)? = nil) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TimedWord] = []
        var currentSpeaker: String?

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            out.append(TranscriptSegment(meetingID: meetingID, source: source, text: text,
                                         startOffset: first.start, endOffset: max(last.end, first.start)))
            current.removeAll()
            currentSpeaker = nil
        }

        for word in words where !word.text.isEmpty {
            let who = speaker?(word)
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let tooLong = word.end - first.start > options.maxDuration
                let sentenceEnded = endsSentence(last.text) && last.end - first.start >= options.minSentenceDuration
                let speakerChanged = who != nil && currentSpeaker != nil && who != currentSpeaker
                if gap > options.pause || tooLong || sentenceEnded || speakerChanged { flush() }
            }
            current.append(word)
            if let who { currentSpeaker = who }
        }
        flush()
        return out
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…".contains(last)
    }
}
