import GranolaCore
import Testing
@testable import GranolaSpeech

@Suite struct SegmentBuilderTests {
    static func words(_ spec: [(String, Double, Double)]) -> [TimedWord] {
        spec.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func splitsOnPauses() {
        let w = Self.words([("so", 0, 0.3), ("the", 0.4, 0.5), ("plan", 0.6, 1.0), ("right", 2.0, 2.3)])
        let s = SegmentBuilder.segments(from: w, meetingID: "m", source: .system)
        #expect(s.map(\.text) == ["so the plan", "right"])
        #expect(s[0].startOffset == 0 && s[0].endOffset == 1.0)
        #expect(s[1].startOffset == 2.0)
        #expect(s.allSatisfy { $0.source == .system && $0.meetingID == "m" })
    }

    @Test func splitsOnSentenceEndsOnceLongEnough() {
        let w = Self.words([("Yes.", 0, 0.3), ("Okay,", 0.4, 0.7), ("we", 0.8, 0.9), ("ship", 1.0, 1.3),
                            ("Thursday.", 1.4, 2.0), ("Great.", 2.1, 2.5)])
        let s = SegmentBuilder.segments(from: w, meetingID: "m", source: .microphone)
        #expect(s.map(\.text) == ["Yes. Okay, we ship Thursday.", "Great."])
    }

    @Test func capsSegmentLength() {
        let w = (0..<60).map { TimedWord(text: "word", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4) }
        let s = SegmentBuilder.segments(from: w, meetingID: "m", source: .system)
        #expect(s.count == 2)
        #expect(s.allSatisfy { $0.endOffset - $0.startOffset <= 20 })
        #expect(s.map { $0.text.split(separator: " ").count }.reduce(0, +) == 60)
    }

    @Test func emptyInput() {
        #expect(SegmentBuilder.segments(from: [], meetingID: "m", source: .system).isEmpty)
    }
}
