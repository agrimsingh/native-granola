import Foundation
import GranolaCore
import Testing
@testable import GranolaIntelligence

@Suite struct NoteEnhancerTests {
    static let meeting = Meeting(
        id: "m1",
        title: "Acme renewal",
        startedAt: Date(timeIntervalSince1970: 1_780_000_000),
        endedAt: Date(timeIntervalSince1970: 1_780_000_000 + 1800),
        attendees: [Attendee(name: "Dana Lee", email: "dana@acme.com"), Attendee(email: "ops@acme.com")],
        sourceApp: "us.zoom.xos",
        rawNotes: "- wants SSO by Q3\n- budget ~$40k"
    )

    static let segments = [
        TranscriptSegment(meetingID: "m1", source: .system, text: "We really need SSO before Q3.", startOffset: 65, endOffset: 68),
        TranscriptSegment(meetingID: "m1", source: .microphone, text: "Understood, I'll send a proposal.", startOffset: 5, endOffset: 7),
    ]

    static func completion(_ content: String) -> MockReply {
        .json(["choices": [["message": ["role": "assistant", "content": .string(content)]]]])
    }

    @Test func promptContainsEverything() throws {
        let template = NoteTemplate.salesCall
        let messages = NoteEnhancer.messages(
            meeting: Self.meeting, segments: Self.segments, template: template, userName: "Agrim",
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[1].role == .user)
        let system = messages[0].content
        let user = messages[1].content
        for section in template.sections { #expect(system.contains("### \(section)")) }
        #expect(system.contains(template.instructions))
        #expect(system.contains("- [ ] Owner: task"))
        #expect(system.contains("\"Me\" is Agrim"))
        #expect(system.contains("\"Them\""))

        #expect(user.contains("Title: Acme renewal"))
        #expect(user.contains("Dana Lee <dana@acme.com>"))
        #expect(user.contains("ops@acme.com"))
        #expect(user.contains("App: Zoom"))
        #expect(user.contains("Duration: 30 minutes"))
        #expect(user.contains("<my_notes>\n- wants SSO by Q3\n- budget ~$40k\n</my_notes>"))
        #expect(user.contains("[00:05] Me: Understood, I'll send a proposal.\n[01:05] Them: We really need SSO before Q3."))
        #expect(user.contains("Agrim"))
    }

    @Test func promptWithoutUserNameOrNotes() {
        var meeting = Self.meeting
        meeting.rawNotes = "  "
        let messages = NoteEnhancer.messages(meeting: meeting, segments: [], template: .general, userName: nil)
        #expect(messages[1].content.contains("<my_notes>\n(none)\n</my_notes>"))
        #expect(messages[1].content.contains("(no transcript)"))
        #expect(messages[0].content.contains("\"Me\" is the user"))
        #expect(messages[0].content.contains("### Summary"))
    }

    @Test func transcriptTruncationKeepsHeadAndTail() {
        let segments = (0..<5000).map {
            TranscriptSegment(meetingID: "m1", source: $0 % 2 == 0 ? .microphone : .system,
                              text: "utterance number \($0) with some padding text", startOffset: Double($0), endOffset: Double($0) + 1)
        }
        let full = Transcript.format(segments)
        #expect(full.count > 100_000)
        let messages = NoteEnhancer.messages(meeting: Self.meeting, segments: segments, template: .general, userName: nil,
                                             maxTranscriptCharacters: 20_000)
        let user = messages[1].content
        #expect(user.contains("utterance number 0 with"))
        #expect(user.contains("utterance number 4999 with"))
        #expect(!user.contains("utterance number 2500 with"))
        #expect(user.contains("transcript truncated"))
        #expect(user.count < 25_000)
    }

    @Test func truncateMiddleNoOpWhenShort() {
        #expect(MeetingContext.truncateMiddle("short", limit: 100) == "short")
        let long = String(repeating: "a", count: 1000)
        let cut = MeetingContext.truncateMiddle(long, limit: 100)
        #expect(cut.hasPrefix(String(repeating: "a", count: 50)))
        #expect(cut.contains("900 characters omitted"))
    }

    @Test func enhanceCallsAPIAndCleansFences() async throws {
        let http = MockHTTP { _, _ in Self.completion("```markdown\n### Summary\n- Renewal discussed\n```") }
        let enhancer = NoteEnhancer(client: XAIClient(apiKey: "k", model: "grok-n", http: http))
        let notes = try await enhancer.enhance(meeting: Self.meeting, segments: Self.segments, template: .general, userName: "Agrim")
        #expect(notes == "### Summary\n- Renewal discussed")
        let body = try bodyJSON(try #require(http.requests.first))
        #expect(body["temperature"]?.doubleValue == 0.3)
        #expect(body["messages"]?.arrayValue?.count == 2)
    }

    @Test func streamEnhanceYieldsDeltas() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"### Sum\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"mary\"}}]}\n\ndata: [DONE]\n\n"
        let http = MockHTTP { _, _ in MockReply(chunks: sseChunks(sse, size: 9)) }
        let enhancer = NoteEnhancer(client: XAIClient(apiKey: "k", model: "m", http: http))
        var out = ""
        for try await d in enhancer.streamEnhance(meeting: Self.meeting, segments: Self.segments, template: .standup) { out += d }
        #expect(out == "### Summary")
        #expect(try bodyJSON(http.requests[0])["stream"] == true)
    }

    @Test func suggestTitleCleansOutput() async throws {
        let http = MockHTTP { _, _ in Self.completion("Title: \"Acme SSO Renewal Discussion.\"\n") }
        let enhancer = NoteEnhancer(client: XAIClient(apiKey: "k", model: "m", http: http))
        let title = try await enhancer.suggestTitle(meeting: Self.meeting, segments: Self.segments)
        #expect(title == "Acme SSO Renewal Discussion")
        let user = try bodyJSON(http.requests[0])["messages"]?[1]?["content"]?.stringValue ?? ""
        #expect(user.contains("We really need SSO"))
    }

    @Test func cleanTitleVariants() {
        #expect(NoteEnhancer.cleanTitle("**Weekly Sync**") == "Weekly Sync")
        #expect(NoteEnhancer.cleanTitle("# Q3 Planning!\nextra") == "Q3 Planning")
        #expect(NoteEnhancer.cleanTitle(String(repeating: "x", count: 200)).count == 80)
    }
}

@Suite struct NoteTemplateTests {
    @Test func builtInsPresent() {
        let ids = NoteTemplate.builtIn.map(\.id)
        #expect(ids == ["general", "one-on-one", "sales-call", "standup", "interview", "customer-discovery", "team-meeting"])
        #expect(Set(ids).count == ids.count)
        #expect(NoteTemplate.default.id == "general")
        #expect(NoteTemplate.named("standup")?.name == "Standup")
        #expect(NoteTemplate.named("nope") == nil)
        for t in NoteTemplate.builtIn {
            #expect(!t.sections.isEmpty)
            #expect(!t.instructions.isEmpty)
        }
    }

    @Test func resolveAndCodable() throws {
        let custom = NoteTemplate(id: "board", name: "Board", description: "d", instructions: "i", sections: ["Metrics"])
        #expect(NoteTemplate.resolve("board", custom: [custom]) == custom)
        #expect(NoteTemplate.resolve("interview").id == "interview")
        #expect(NoteTemplate.resolve(nil).id == "general")
        #expect(NoteTemplate.resolve("missing").id == "general")
        let data = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(NoteTemplate.self, from: data) == custom)
    }
}

@Suite struct MeetingChatTests {
    @Test func promptGroundsInMeetingsWithCitations() throws {
        var m1 = NoteEnhancerTests.meeting
        m1.enhancedNotes = "### Summary\n- SSO is required"
        let m2 = Meeting(id: "m2", title: "Hiring sync", startedAt: Date(timeIntervalSince1970: 1_780_500_000), rawNotes: "hire 2 engineers")
        let s2 = [TranscriptSegment(meetingID: "m2", source: .system, text: "Let's open two roles.", startOffset: 1, endOffset: 2)]
        let messages = MeetingChat.messages(
            question: "What did Acme ask for?",
            meetings: [(m1, NoteEnhancerTests.segments), (m2, s2)],
            history: [.user("hi"), .assistant("hello")],
            userName: "Agrim",
            now: Date(timeIntervalSince1970: 1_781_000_000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(messages[0].content.contains("(Meeting Title, Mon D, YYYY)"))
        #expect(messages[0].content.contains("Agrim"))
        let user = messages[3].content
        #expect(user.contains("Title: Acme renewal"))
        #expect(user.contains("Title: Hiring sync"))
        #expect(user.contains("SSO is required"))
        #expect(user.contains("hire 2 engineers"))
        #expect(user.contains("Them: Let's open two roles."))
        #expect(user.hasSuffix("Question: What did Acme ask for?"))
    }

    @Test func contextBudgetTruncatesTranscripts() {
        let segments = (0..<3000).map {
            TranscriptSegment(meetingID: "m", source: .system, text: "chunk \($0) of a very long meeting", startOffset: Double($0), endOffset: Double($0))
        }
        let meetings = (0..<3).map { (Meeting(id: "m\($0)", title: "Meeting \($0)"), segments) }
        let context = MeetingChat.buildContext(meetings: meetings, budget: 30_000, timeZone: .current)
        #expect(context.count < 36_000)
        #expect(context.contains("Meeting 2"))
        #expect(context.contains("transcript truncated"))
    }

    @Test func askUsesClient() async throws {
        let http = MockHTTP { _, _ in NoteEnhancerTests.completion("  Acme wants SSO (Acme renewal, Jun 3, 2026).  ") }
        let chat = MeetingChat(client: XAIClient(apiKey: "k", model: "m", http: http))
        let answer = try await chat.ask(question: "What?", meetings: [(NoteEnhancerTests.meeting, NoteEnhancerTests.segments)])
        #expect(answer == "Acme wants SSO (Acme renewal, Jun 3, 2026).")
    }

    @Test func streamUsesClient() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Yes\"}}]}\n\ndata: [DONE]\n\n"
        let http = MockHTTP { _, _ in MockReply(chunks: [Data(sse.utf8)]) }
        let chat = MeetingChat(client: XAIClient(apiKey: "k", model: "m", http: http))
        var out = ""
        for try await d in chat.stream(question: "Q?", meetings: []) { out += d }
        #expect(out == "Yes")
    }
}
