import GranolaCore
import Testing
@testable import GranolaSpeech

@Suite struct SpeakerAssignmentTests {
    static func seg(_ id: String, _ source: TranscriptSource, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(id: id, meetingID: "m", source: source, text: id, startOffset: start, endOffset: end)
    }

    @Test func assignsMostOverlapAndNumbersByFirstAppearance() {
        let segments = [
            Self.seg("s3", .system, 20, 26),
            Self.seg("s1", .system, 0, 5),
            Self.seg("me", .microphone, 6, 9),
            Self.seg("s2", .system, 10, 16),
        ]
        // Diarizer ids are arbitrary; "B" talks first so it becomes Speaker 1.
        let turns = [
            SpeakerTurn(speakerID: "B", start: 0, end: 5.5),
            SpeakerTurn(speakerID: "A", start: 9.5, end: 14),
            SpeakerTurn(speakerID: "B", start: 14, end: 16),
            SpeakerTurn(speakerID: "A", start: 19, end: 22),
            SpeakerTurn(speakerID: "C", start: 22, end: 27),
        ]
        let labels = SpeakerAssignment.labels(for: segments, turns: turns)
        #expect(labels["s1"] == "Speaker 1")
        #expect(labels["s2"] == "Speaker 2")
        #expect(labels["s3"] == "Speaker 3")
        #expect(labels["me"] == .some(nil))
        #expect(labels.count == 4)
    }

    @Test func singleRemoteSpeakerKeepsThem() {
        let segments = [Self.seg("a", .system, 0, 4), Self.seg("b", .system, 5, 8), Self.seg("me", .microphone, 4, 5)]
        let turns = [SpeakerTurn(speakerID: "X", start: 0, end: 10)]
        let labels = SpeakerAssignment.labels(for: segments, turns: turns)
        #expect(labels.count == 3)
        #expect(labels.values.allSatisfy { $0 == nil })
    }

    @Test func unusedDiarizerSpeakersDontCount() {
        let segments = [Self.seg("a", .system, 0, 4)]
        let turns = [SpeakerTurn(speakerID: "X", start: 0, end: 4), SpeakerTurn(speakerID: "Y", start: 30, end: 40)]
        #expect(SpeakerAssignment.labels(for: segments, turns: turns)["a"] == .some(nil))
    }

    @Test func zeroLengthSegmentUsesNearbyTurn() {
        let segments = [Self.seg("a", .system, 0, 3), Self.seg("b", .system, 10.2, 10.2), Self.seg("c", .system, 50, 50)]
        let turns = [SpeakerTurn(speakerID: "X", start: 0, end: 3), SpeakerTurn(speakerID: "Y", start: 7, end: 10)]
        let labels = SpeakerAssignment.labels(for: segments, turns: turns)
        #expect(labels["a"] == "Speaker 1")
        #expect(labels["b"] == "Speaker 2")
        #expect(labels["c"] == .some(nil))
    }

    @Test func renameAppliesNamesToLabels() {
        var a = Self.seg("a", .system, 0, 1); a.speaker = "Speaker 1"
        var b = Self.seg("b", .system, 1, 2); b.speaker = "Speaker 2"
        let me = Self.seg("me", .microphone, 2, 3)
        let renamed = SpeakerAssignment.rename([a, b, me], names: ["Speaker 2": "Priya Shah"])
        #expect(renamed == ["b": "Priya Shah"])
    }
}
