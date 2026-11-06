import Foundation
import GranolaCore

/// Turns a transcript + the user's raw notes + calendar context into Granola-style "enhanced notes".
public struct NoteEnhancer: Sendable {
    public static let maxTranscriptCharacters = 400_000

    public var client: XAIClient
    /// Overrides the client's model when set.
    public var model: String?
    public var temperature: Double
    public var maxTranscriptCharacters: Int

    public init(
        client: XAIClient,
        model: String? = nil,
        temperature: Double = 0.3,
        maxTranscriptCharacters: Int = NoteEnhancer.maxTranscriptCharacters
    ) {
        self.client = client
        self.model = model
        self.temperature = temperature
        self.maxTranscriptCharacters = maxTranscriptCharacters
    }

    public func enhance(
        meeting: Meeting,
        segments: [TranscriptSegment],
        template: NoteTemplate = .default,
        userName: String? = nil
    ) async throws -> String {
        let messages = Self.messages(
            meeting: meeting, segments: segments, template: template, userName: userName,
            maxTranscriptCharacters: maxTranscriptCharacters
        )
        let output = try await client.complete(messages: messages, model: model, temperature: temperature)
        let notes = Self.cleanOutput(output)
        if notes.isEmpty { throw XAIError.emptyResponse }
        return notes
    }

    /// Streams the notes as markdown deltas. Callers should run the concatenated result through `cleanOutput`.
    public func streamEnhance(
        meeting: Meeting,
        segments: [TranscriptSegment],
        template: NoteTemplate = .default,
        userName: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let messages = Self.messages(
            meeting: meeting, segments: segments, template: template, userName: userName,
            maxTranscriptCharacters: maxTranscriptCharacters
        )
        return client.stream(messages: messages, model: model, temperature: temperature)
    }

    /// A short title for meetings without a calendar title.
    public func suggestTitle(meeting: Meeting, segments: [TranscriptSegment]) async throws -> String {
        let messages = Self.titleMessages(meeting: meeting, segments: segments)
        let raw = try await client.complete(messages: messages, model: model, temperature: 0.2)
        let title = Self.cleanTitle(raw)
        if title.isEmpty { throw XAIError.emptyResponse }
        return title
    }

    // MARK: Prompt construction

    public static func systemPrompt(template: NoteTemplate, userName: String?) -> String {
        let me = (userName?.isEmpty == false) ? userName! : "the user"
        let owner = (userName?.isEmpty == false) ? userName! : "Me"
        let sectionList = template.sections.enumerated().map { "\($0.offset + 1). ### \($0.element)" }.joined(separator: "\n")
        return """
            You are an expert meeting note-taker. You turn a meeting transcript and the user's own rough notes into \
            concise, well-structured meeting notes that the user can skim in under a minute.

            ## Inputs
            - <meeting_context>: calendar details such as title, date, duration, attendees and app.
            - <my_notes>: the rough notes \(me) typed during the meeting. They are the strongest signal of what \
            mattered to the user.
            - <transcript>: automatic speech recognition, one line per utterance as "[mm:ss] Speaker: text". \
            "Me" is \(me). "Them" is everyone else on the call, captured from the computer's audio: it may be one \
            person or several, and individual speakers cannot be told apart. Use the attendee list and the \
            conversation itself to attribute statements to specific people only when it is clear. The transcript \
            contains recognition errors; infer the intended words from context (especially names and jargon, \
            preferring spellings from the attendee list and notes), but never invent content.

            ## Format
            - Output Markdown only. Begin directly with the first `###` header. No document title, no preamble, \
            no closing remarks, and never mention AI, transcripts, or how the notes were produced.
            - Organize the notes under `###` headers using these sections, in this order:
            \(sectionList)
            - Omit a section entirely if nothing relevant was discussed; never write placeholders like "None" or \
            "N/A". You may add another `###` section only for important content that fits nowhere else.
            - Under each header, use concise "- " bullet points. Indent sub-bullets by two spaces for supporting \
            detail. Write crisp, specific statements; fragments are fine. No filler, no generic commentary.
            - Use **bold** sparingly for key numbers, names and decisions.

            ## Content rules
            - Every point in <my_notes> must appear in the output. Expand each one with the relevant detail and \
            context from the transcript (who, what, numbers, dates, reasons) and keep the user's terminology. Never \
            drop or contradict a note; if the transcript doesn't cover it, keep it as written.
            - Capture concrete specifics: numbers, prices, metrics, dates, deadlines, names of people, companies \
            and products.
            - State decisions explicitly (e.g. "Decided to …"). Do not present suggestions, options or open \
            questions as decisions.
            - Write each action item as "- [ ] Owner: task" (add the due date if one was mentioned). Use attendee \
            names when the owner can be inferred, "\(owner)" for things the user committed to, and "Them" only when \
            the other side committed but the person can't be determined.
            - Be faithful: include only what was actually said or written. Do not speculate, add advice, or pad. \
            If the transcript is empty or very short, rely on <my_notes> and keep the notes short.
            - Write in the same language as the meeting.

            ## Meeting type: \(template.name)
            \(template.description)
            \(template.instructions)
            """
    }

    public static func messages(
        meeting: Meeting,
        segments: [TranscriptSegment],
        template: NoteTemplate,
        userName: String?,
        maxTranscriptCharacters: Int = NoteEnhancer.maxTranscriptCharacters,
        timeZone: TimeZone = .current
    ) -> [ChatMessage] {
        let transcript = MeetingContext.truncateMiddle(Transcript.format(segments), limit: maxTranscriptCharacters)
        let notes = meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = """
            <meeting_context>
            \(MeetingContext.describe(meeting, userName: userName, timeZone: timeZone))
            </meeting_context>

            <my_notes>
            \(notes.isEmpty ? "(none)" : notes)
            </my_notes>

            <transcript>
            \(transcript.isEmpty ? "(no transcript)" : transcript)
            </transcript>

            Write the enhanced notes now, following the "\(template.name)" sections.
            """
        return [.system(systemPrompt(template: template, userName: userName)), .user(user)]
    }

    static func titleMessages(meeting: Meeting, segments: [TranscriptSegment]) -> [ChatMessage] {
        let transcript = MeetingContext.truncateMiddle(Transcript.format(segments), limit: 40_000)
        let notes = meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let enhanced = meeting.enhancedNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts = ["<meeting_context>\n\(MeetingContext.describe(meeting, userName: nil))\n</meeting_context>"]
        if !notes.isEmpty { parts.append("<my_notes>\n\(notes)\n</my_notes>") }
        if !enhanced.isEmpty { parts.append("<enhanced_notes>\n\(enhanced.prefix(20_000))\n</enhanced_notes>") }
        parts.append("<transcript>\n\(transcript.isEmpty ? "(no transcript)" : transcript)\n</transcript>")
        let system = """
            You name meetings. Given a meeting's context, notes and transcript, reply with a short, specific title \
            of 2–7 words that says what the meeting was about (e.g. "Acme Pricing Negotiation", "Q3 Roadmap \
            Review", "Weekly Sync with Dana"). Reply with the title only: no quotes, no trailing punctuation, no \
            explanation. Use the meeting's language.
            """
        return [.system(system), .user(parts.joined(separator: "\n\n"))]
    }

    /// Strips wrapping code fences and stray whitespace from model output.
    public static func cleanOutput(_ text: String) -> String {
        MeetingContext.stripCodeFence(text)
    }

    static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = t.split(whereSeparator: \.isNewline).first { t = String(firstLine) }
        for prefix in ["Title:", "title:", "#"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"'“”‘’`").union(.whitespaces))
        while let last = t.last, ".!;:,".contains(last) { t.removeLast() }
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}
