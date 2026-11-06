import Foundation
import GranolaCore

/// A stretch of audio attributed to one diarized speaker, in seconds from the start of the file.
public struct SpeakerTurn: Sendable, Hashable, Codable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public enum SpeakerAssignment {
    /// Labels each system segment with the diarized speaker it overlaps most, as "Speaker 1", "Speaker 2", …
    /// numbered by first appearance in the transcript. Microphone segments are always nil ("Me"). When
    /// fewer than two remote speakers end up in the transcript, every label is nil so the UI keeps "Them".
    /// Returns a label for every segment id.
    public static func labels(for segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [String: String?] {
        var raw: [(segment: TranscriptSegment, speaker: String?)] = []
        for segment in segments.sorted(by: { $0.startOffset < $1.startOffset }) {
            raw.append((segment, segment.source == .system ? dominantSpeaker(segment, turns: turns) : nil))
        }
        var numbers: [String: Int] = [:]
        for case let (_, speaker?) in raw where numbers[speaker] == nil {
            numbers[speaker] = numbers.count + 1
        }
        let distinct = numbers.count >= 2
        var out: [String: String?] = [:]
        for (segment, speaker) in raw {
            let label = distinct ? speaker.flatMap { numbers[$0] }.map { "Speaker \($0)" } : nil
            out.updateValue(label, forKey: segment.id)
        }
        return out
    }

    static func dominantSpeaker(_ segment: TranscriptSegment, turns: [SpeakerTurn]) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let o = min(segment.endOffset, turn.end) - max(segment.startOffset, turn.start)
            if o > 0 { overlap[turn.speakerID, default: 0] += o }
        }
        if let best = overlap.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return best.key
        }
        // Zero-length or unaligned segments: take the nearest turn within a second.
        let mid = (segment.startOffset + segment.endOffset) / 2
        let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
        return nearest.flatMap { distance(mid, $0) <= 1 ? $0.speakerID : nil }
    }

    private static func distance(_ t: TimeInterval, _ turn: SpeakerTurn) -> TimeInterval {
        t < turn.start ? turn.start - t : t > turn.end ? t - turn.end : 0
    }

    /// Applies names (e.g. "Speaker 2" → "Priya Shah") to existing labels.
    public static func rename(_ segments: [TranscriptSegment], names: [String: String]) -> [String: String?] {
        var out: [String: String?] = [:]
        for s in segments {
            if let label = s.speaker, let name = names[label] { out[s.id] = name }
        }
        return out
    }
}
