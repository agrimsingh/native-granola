import Foundation
import GranolaCore
import Testing
@testable import GranolaIntelligence

@Suite struct SpeakerNamingTests {
    static let meeting = Meeting(
        id: "m1", title: "Launch sync",
        attendees: [Attendee(name: "Priya Shah", email: "priya@example.com"),
                    Attendee(name: "Marcus Lee", email: "marcus@example.com"),
                    Attendee(name: "Agrim Singh"), Attendee(email: "ops@example.com")])

    static func seg(_ source: TranscriptSource, _ speaker: String?, _ text: String, _ t: Double) -> TranscriptSegment {
        TranscriptSegment(meetingID: "m1", source: source, text: text, startOffset: t, endOffset: t + 2, speaker: speaker)
    }

    static let segments = [
        seg(.microphone, nil, "Priya, can you own the onboarding emails?", 0),
        seg(.system, "Speaker 1", "Yes, I'll have drafts by Monday.", 3),
        seg(.system, "Speaker 2", "Hi all, Dana here, sorry I'm late.", 6),
        seg(.system, "Speaker 10", "I'll update the pricing table.", 9),
    ]

    static func completion(_ content: String) -> MockReply {
        .json(["choices": [["message": ["role": "assistant", "content": .string(content)]]]])
    }

    @Test func promptListsLabelsAttendeesAndTranscript() {
        let messages = SpeakerNamer.messages(meeting: Self.meeting, segments: Self.segments, userName: "Agrim Singh")
        #expect(messages.count == 2)
        let system = messages[0].content, user = messages[1].content
        #expect(system.contains("Speaker 1, Speaker 2, Speaker 10"))
        #expect(system.contains("\"Me\" is Agrim Singh"))
        #expect(system.contains("Never assign Agrim Singh"))
        #expect(system.contains("\"speakers\": [{\"label\": \"Speaker 1\""))
        #expect(system.contains("never the person who said the name"))
        #expect(user.contains("<attendees>\nPriya Shah\nMarcus Lee\nAgrim Singh\n</attendees>"))
        #expect(!user.contains("ops@example.com"))
        #expect(user.contains("[00:00] Me: Priya, can you own the onboarding emails?"))
        #expect(user.contains("[00:03] Speaker 1: Yes, I'll have drafts by Monday."))
    }

    @Test func parseKeepsOnlyConfidentGroundedNames() {
        let raw = """
            ```json
            {"speakers": [
              {"label": "Speaker 1", "name": "Priya", "confidence": "high", "evidence": "Priya, can you…"},
              {"label": "Speaker 2", "name": "Dana", "confidence": "high"},
              {"label": "Speaker 10", "name": "Marcus Lee", "confidence": "low"},
              {"label": "Speaker 3", "name": "Marcus Lee", "confidence": "high"},
              {"label": "Speaker 2", "name": "Priya Shah", "confidence": "high"}
            ]}
            ```
            """
        let names = SpeakerNamer.parse(raw, labels: ["Speaker 1", "Speaker 2", "Speaker 10"],
                                       attendees: Self.meeting.attendees,
                                       transcript: Self.segments.map(\.text).joined(separator: "\n"), userName: "Agrim Singh")
        #expect(names == ["Speaker 1": "Priya Shah", "Speaker 2": "Dana"])
    }

    @Test func parseRejectsInventedUserAndDuplicateNames() {
        let transcript = Self.segments.map(\.text).joined(separator: "\n")
        let raw = """
            {"speakers": [
              {"label": "Speaker 1", "name": "Jordan Blake", "confidence": "high"},
              {"label": "Speaker 2", "name": "Agrim", "confidence": "high"},
              {"label": "Speaker 10", "name": "Marcus", "confidence": "high"}
            ]}
            """
        let names = SpeakerNamer.parse(raw, labels: ["Speaker 1", "Speaker 2", "Speaker 10"],
                                       attendees: Self.meeting.attendees, transcript: transcript, userName: "Agrim Singh")
        #expect(names == ["Speaker 10": "Marcus Lee"])

        let dup = """
            {"speakers": [{"label": "Speaker 1", "name": "Priya Shah", "confidence": "high"},
                          {"label": "Speaker 2", "name": "priya", "confidence": "high"}]}
            """
        #expect(SpeakerNamer.parse(dup, labels: ["Speaker 1", "Speaker 2"], attendees: Self.meeting.attendees,
                                   transcript: transcript, userName: nil).isEmpty)
        #expect(SpeakerNamer.parse("I can't tell.", labels: ["Speaker 1"], attendees: [], transcript: "",
                                   userName: nil).isEmpty)
    }

    @Test func nameSpeakersCallsAPI() async throws {
        let http = MockHTTP { _, _ in
            Self.completion(#"{"speakers": [{"label": "Speaker 1", "name": "Priya Shah", "confidence": "high"}]}"#)
        }
        let namer = SpeakerNamer(client: XAIClient(apiKey: "k", model: "grok-n", http: http))
        let names = try await namer.nameSpeakers(meeting: Self.meeting, segments: Self.segments, userName: "Agrim Singh")
        #expect(names == ["Speaker 1": "Priya Shah"])
        let body = try bodyJSON(try #require(http.requests.first))
        #expect(body["temperature"]?.doubleValue == 0)
        #expect(body["model"]?.stringValue == "grok-n")
    }

    @Test func skipsAPIWithoutDiarizedLabels() async throws {
        let http = MockHTTP { _, _ in Self.completion("{}") }
        let namer = SpeakerNamer(client: XAIClient(apiKey: "k", http: http))
        let plain = [Self.seg(.system, nil, "hello", 0), Self.seg(.system, "Priya Shah", "hi", 2)]
        #expect(try await namer.nameSpeakers(meeting: Self.meeting, segments: plain, userName: nil).isEmpty)
        #expect(http.requests.isEmpty)
    }
}
