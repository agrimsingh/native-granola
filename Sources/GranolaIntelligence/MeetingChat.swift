import Foundation
import GranolaCore

/// Answers questions grounded in a set of meetings (notes + transcripts), citing title and date.
public struct MeetingChat: Sendable {
    public static let maxContextCharacters = 400_000

    public var client: XAIClient
    public var model: String?
    public var temperature: Double
    public var maxContextCharacters: Int
    /// The user's name, so "Me" in transcripts can be resolved.
    public var userName: String?

    public init(
        client: XAIClient,
        model: String? = nil,
        temperature: Double = 0.2,
        maxContextCharacters: Int = MeetingChat.maxContextCharacters,
        userName: String? = nil
    ) {
        self.client = client
        self.model = model
        self.temperature = temperature
        self.maxContextCharacters = maxContextCharacters
        self.userName = userName
    }

    /// `history` holds prior turns of this chat (user/assistant), oldest first.
    public func ask(
        question: String,
        meetings: [(Meeting, [TranscriptSegment])],
        history: [ChatMessage] = []
    ) async throws -> String {
        let messages = Self.messages(
            question: question, meetings: meetings, history: history, userName: userName,
            maxContextCharacters: maxContextCharacters
        )
        let answer = try await client.complete(messages: messages, model: model, temperature: temperature)
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stream(
        question: String,
        meetings: [(Meeting, [TranscriptSegment])],
        history: [ChatMessage] = []
    ) -> AsyncThrowingStream<String, Error> {
        let messages = Self.messages(
            question: question, meetings: meetings, history: history, userName: userName,
            maxContextCharacters: maxContextCharacters
        )
        return client.stream(messages: messages, model: model, temperature: temperature)
    }

    public static func systemPrompt(userName: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let me = (userName?.isEmpty == false) ? userName! : "the user"
        return """
            You are a helpful assistant that answers questions about \(me)'s meetings. You are given meeting \
            records inside <meetings>, each with its title, date, attendees, notes and transcript.

            Rules:
            - Answer using only information in the provided meetings. If the answer isn't there, say so plainly \
            rather than guessing.
            - Cite the source of each claim inline as (Meeting Title, Mon D, YYYY), e.g. (Weekly Sync, Mar 4, 2026).
            - In transcripts, "Me" is \(me); "Them" is the other participant(s), captured together from computer \
            audio, so individual speakers can't be distinguished. Transcripts contain speech-recognition errors.
            - Be concise and direct. Use Markdown: short paragraphs or bullets; action items as "- [ ] Owner: task".
            - When asked to draft something (email, summary, follow-up), write it ready to send, without preamble.
            - Today is \(MeetingContext.longDate(now, timeZone: timeZone)). Interpret relative dates ("last \
            week", "yesterday") against this.
            """
    }

    public static func messages(
        question: String,
        meetings: [(Meeting, [TranscriptSegment])],
        history: [ChatMessage] = [],
        userName: String? = nil,
        maxContextCharacters: Int = MeetingChat.maxContextCharacters,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [ChatMessage] {
        let context = buildContext(meetings: meetings, budget: maxContextCharacters, timeZone: timeZone)
        let user = """
            <meetings>
            \(context.isEmpty ? "(no meetings provided)" : context)
            </meetings>

            Question: \(question)
            """
        return [.system(systemPrompt(userName: userName, now: now, timeZone: timeZone))] + history + [.user(user)]
    }

    /// Notes are always included (each capped); remaining budget is split evenly across transcripts.
    static func buildContext(meetings: [(Meeting, [TranscriptSegment])], budget: Int, timeZone: TimeZone) -> String {
        guard !meetings.isEmpty else { return "" }
        let noteCap = max(2_000, min(20_000, budget / (meetings.count * 4)))
        var headers: [String] = []
        var noteBlocks: [String] = []
        var transcripts: [String] = []
        for (meeting, segments) in meetings {
            var header = "Title: \(meeting.title.isEmpty ? "(untitled)" : meeting.title)\n"
            header += "Date: \(MeetingContext.longDate(meeting.startedAt, timeZone: timeZone))"
            if let minutes = MeetingContext.durationMinutes(meeting) { header += "\nDuration: \(minutes) minutes" }
            if !meeting.attendees.isEmpty { header += "\nAttendees: \(MeetingContext.attendeeList(meeting.attendees))" }
            if let folder = meeting.folder, !folder.isEmpty { header += "\nFolder: \(folder)" }
            headers.append(header)

            var notes = ""
            if let enhanced = meeting.enhancedNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !enhanced.isEmpty {
                notes += "<enhanced_notes>\n\(MeetingContext.truncateMiddle(enhanced, limit: noteCap, noun: "notes"))\n</enhanced_notes>\n"
            }
            let raw = meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                notes += "<my_notes>\n\(MeetingContext.truncateMiddle(raw, limit: noteCap, noun: "notes"))\n</my_notes>\n"
            }
            noteBlocks.append(notes)
            transcripts.append(Transcript.format(segments))
        }
        let fixed = zip(headers, noteBlocks).reduce(0) { $0 + $1.0.count + $1.1.count + 64 }
        let transcriptBudget = max(1_000, (budget - fixed) / meetings.count)
        var parts: [String] = []
        for i in meetings.indices {
            var block = "<meeting index=\"\(i + 1)\">\n\(headers[i])\n\(noteBlocks[i])"
            if !transcripts[i].isEmpty {
                block += "<transcript>\n\(MeetingContext.truncateMiddle(transcripts[i], limit: transcriptBudget))\n</transcript>\n"
            }
            block += "</meeting>"
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }
}
