import Foundation
import GranolaCore

/// The read-only MCP tools over the meeting store. Each tool returns markdown text.
final class MeetingTools {
    let store: Store
    let format: Formatting
    private let now: () -> Date

    static let defaultTranscriptChars = 100_000
    static let speakerLegend = "Speakers: \"Me\" = the user (microphone); \"Them\" = other participants (system audio). Timestamps are offsets from the meeting start."

    init(store: Store, format: Formatting, now: @escaping () -> Date) {
        self.store = store
        self.format = format
        self.now = now
    }

    // MARK: Definitions

    static let names: Set<String> = Set(definitions.compactMap { $0["name"] as? String })

    static let definitions: [[String: Any]] = [
        tool(
            name: "list_meetings",
            title: "List meetings",
            description: """
                List the user's recorded meetings, newest first. Each entry has the meeting id, title, start \
                time, duration (or "in progress"), attendees and whether AI-enhanced notes exist. Use this to \
                browse recent meetings or meetings in a date range (e.g. "my meetings yesterday"), then call \
                get_meeting with an id for details. To find meetings about a topic, use search_meetings instead.
                """,
            properties: [
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20,
                          "description": "Maximum number of meetings to return (1-100, default 20)."],
                "since": ["type": "string",
                          "description": "Only meetings starting at or after this time. ISO 8601 datetime or YYYY-MM-DD (local day start)."],
                "until": ["type": "string",
                          "description": "Only meetings starting at or before this time. ISO 8601 datetime or YYYY-MM-DD (inclusive of that whole local day)."],
            ]),
        tool(
            name: "get_meeting",
            title: "Get meeting",
            description: """
                Get one meeting's details: title, date, duration, attendees, source app, the AI-enhanced notes, \
                the user's own typed notes, and the Notion page URL if it was exported. Set include_transcript \
                to also get the full timestamped transcript ("Me" = the user via microphone, "Them" = other \
                participants via system audio). Get meeting ids from list_meetings or search_meetings.
                """,
            properties: [
                "meeting_id": ["type": "string", "description": "The meeting id."],
                "include_transcript": ["type": "boolean", "default": false,
                                       "description": "Also include the transcript (default false)."],
            ],
            required: ["meeting_id"]),
        tool(
            name: "get_transcript",
            title: "Get transcript",
            description: """
                Get the full timestamped transcript of a meeting as "[mm:ss] Speaker: text" lines. "Me" is the \
                user (captured from their microphone); "Them" is the other participants (captured from system \
                audio; individual remote speakers are not distinguished). Use this to answer detailed questions \
                about what was said. Long transcripts are truncated to max_chars, keeping the beginning.
                """,
            properties: [
                "meeting_id": ["type": "string", "description": "The meeting id."],
                "max_chars": ["type": "integer", "minimum": 1000, "default": defaultTranscriptChars,
                              "description": "Maximum transcript characters to return (default 100000). If exceeded, the beginning is kept and truncation is noted."],
            ],
            required: ["meeting_id"]),
        tool(
            name: "search_meetings",
            title: "Search meetings",
            description: """
                Full-text search across all meetings' titles, the user's notes, AI-enhanced notes and \
                transcripts. Results are grouped by meeting, with matching snippets (matches in **bold**) and \
                timestamps for transcript matches. All words must match; the last word matches as a prefix. \
                Use this to find meetings about a topic, project, customer or person.
                """,
            properties: [
                "query": ["type": "string", "description": "Words to search for."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20,
                          "description": "Maximum number of matches to return (1-100, default 20)."],
            ],
            required: ["query"]),
        tool(
            name: "get_current_meeting",
            title: "Get current meeting",
            description: """
                Get the meeting that is being recorded right now (if any): its title, attendees, the user's notes \
                so far, and the transcript of the last few minutes ("Me" = the user via microphone, "Them" = other \
                participants via system audio). Use this when the user asks about the call they are in, e.g. \
                "what did they just say?" or "summarize this meeting so far".
                """,
            properties: [
                "last_minutes": ["type": "integer", "minimum": 1, "maximum": 240, "default": 10,
                                 "description": "How many minutes of recent transcript to include (default 10)."],
            ]),
    ]

    private static func tool(name: String, title: String, description: String,
                             properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            "annotations": ["title": title, "readOnlyHint": true, "openWorldHint": false],
        ]
    }

    // MARK: Dispatch

    /// Runs a tool and wraps the outcome as an MCP `CallToolResult`. `name` must be in `names`.
    func call(name: String, arguments args: Arguments) -> [String: Any] {
        do {
            let text: String
            switch name {
            case "list_meetings": text = try listMeetings(args)
            case "get_meeting": text = try getMeeting(args)
            case "get_transcript": text = try getTranscript(args)
            case "search_meetings": text = try searchMeetings(args)
            case "get_current_meeting": text = try getCurrentMeeting(args)
            default: throw ToolError("Unknown tool: \(name)")
            }
            return Self.result(text, isError: false)
        } catch let error as ToolError {
            return Self.result(error.message, isError: true)
        } catch {
            return Self.result("Failed to read the meetings database: \(error)", isError: true)
        }
    }

    private static func result(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    // MARK: Tools

    private func listMeetings(_ args: Arguments) throws -> String {
        let limit = try args.int("limit", default: 20, range: 1...100)
        let since = try args.date("since", endOfDay: false)
        let until = try args.date("until", endOfDay: true)
        if let since, let until, since > until { throw ToolError("'since' must be before 'until'.") }

        let meetings = try store.listMeetings(limit: limit, since: since, until: until)
        var range = ""
        if let since { range += " since \(format.date(since))" }
        if let until { range += " until \(format.date(until))" }
        guard !meetings.isEmpty else { return "No meetings found\(range)." }

        var lines = ["\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")\(range), newest first:", ""]
        for (i, m) in meetings.enumerated() {
            lines.append("\(i + 1). **\(m.title)**")
            lines.append("   - id: `\(m.id)`")
            lines.append("   - start: \(format.date(m.startedAt))")
            lines.append("   - duration: \(format.duration(of: m))")
            lines.append("   - attendees: \(format.attendees(m.attendees))")
            if let folder = m.folder { lines.append("   - folder: \(folder)") }
            lines.append("   - enhanced notes: \(hasText(m.enhancedNotes) ? "yes" : "no")")
        }
        if meetings.count == limit {
            lines += ["", "_Showing at most \(limit). Use since/until or a larger limit to see more._"]
        }
        return lines.joined(separator: "\n")
    }

    private func getMeeting(_ args: Arguments) throws -> String {
        let m = try meeting(args)
        let includeTranscript = try args.bool("include_transcript", default: false)
        var lines = ["# \(m.title)", ""] + header(m)
        if let url = m.notionPageURL, !url.isEmpty { lines.append("- Notion page: \(url)") }

        lines += ["", "## Enhanced notes (AI-generated)", ""]
        lines.append(hasText(m.enhancedNotes) ? m.enhancedNotes! : "_No enhanced notes yet._")
        lines += ["", "## User's own notes", ""]
        lines.append(hasText(m.rawNotes) ? m.rawNotes : "_The user did not type any notes._")

        let segments = try store.segments(meetingID: m.id)
        lines += ["", "## Transcript", ""]
        if segments.isEmpty {
            lines.append("_No transcript recorded._")
        } else if includeTranscript {
            lines += [Self.speakerLegend, "", truncated(Transcript.format(segments), maxChars: Self.defaultTranscriptChars)]
        } else {
            lines.append("_\(segments.count) transcript segments available. Call get_transcript (or get_meeting with include_transcript=true) to read them._")
        }
        return lines.joined(separator: "\n")
    }

    private func getTranscript(_ args: Arguments) throws -> String {
        let m = try meeting(args)
        let maxChars = try args.int("max_chars", default: Self.defaultTranscriptChars, range: 1000...10_000_000)
        let segments = try store.segments(meetingID: m.id)
        var lines = ["# Transcript: \(m.title)", "", "\(format.date(m.startedAt)) · \(format.duration(of: m)) · \(segments.count) segments", ""]
        guard !segments.isEmpty else { return (lines + ["_No transcript recorded for this meeting._"]).joined(separator: "\n") }
        lines += [Self.speakerLegend, "", truncated(Transcript.format(segments), maxChars: maxChars)]
        return lines.joined(separator: "\n")
    }

    private func searchMeetings(_ args: Arguments) throws -> String {
        let query = try args.requiredString("query")
        let limit = try args.int("limit", default: 20, range: 1...100)
        let hits = try store.search(query, limit: limit)
        guard !hits.isEmpty else { return "No meetings matched \"\(query)\"." }

        var order: [String] = []
        var groups: [String: [SearchHit]] = [:]
        for hit in hits {
            if groups[hit.meetingID] == nil { order.append(hit.meetingID) }
            groups[hit.meetingID, default: []].append(hit)
        }
        var lines = ["\(hits.count) match\(hits.count == 1 ? "" : "es") in \(order.count) meeting\(order.count == 1 ? "" : "s") for \"\(query)\":"]
        for id in order {
            let group = groups[id]!
            lines += ["", "## \(group[0].meetingTitle)", "- id: `\(id)`", "- start: \(format.date(group[0].meetingStartedAt))"]
            for hit in group {
                let snippet = hit.snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
                lines.append("- \(label(hit)): \(snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func getCurrentMeeting(_ args: Arguments) throws -> String {
        let minutes = try args.int("last_minutes", default: 10, range: 1...240)
        guard let m = try store.listMeetings(limit: 50).first(where: \.isInProgress) else {
            return "No meeting is in progress right now. Use list_meetings to see past meetings."
        }
        var lines = ["# In progress: \(m.title)", "", "- id: `\(m.id)`",
                     "- started: \(format.date(m.startedAt)) (\(format.duration(now().timeIntervalSince(m.startedAt))) ago)",
                     "- attendees: \(format.attendees(m.attendees))"]
        if let app = m.sourceApp { lines.append("- source app: \(format.sourceApp(app))") }
        lines += ["", "## User's own notes so far", ""]
        lines.append(hasText(m.rawNotes) ? m.rawNotes : "_The user has not typed any notes yet._")

        lines += ["", "## Transcript: last \(minutes) minute\(minutes == 1 ? "" : "s")", ""]
        let segments = try store.segments(meetingID: m.id)
        guard let lastEnd = segments.map(\.endOffset).max() else {
            return (lines + ["_No transcript yet._"]).joined(separator: "\n")
        }
        let cutoff = lastEnd - Double(minutes) * 60
        let recent = segments.filter { $0.endOffset >= cutoff }
        lines += [Self.speakerLegend, "", Transcript.format(recent)]
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private func meeting(_ args: Arguments) throws -> Meeting {
        let id = try args.requiredString("meeting_id")
        guard let m = try store.meeting(id: id) else {
            throw ToolError("No meeting with id \"\(id)\". Use list_meetings or search_meetings to find valid ids.")
        }
        return m
    }

    private func header(_ m: Meeting) -> [String] {
        var lines = ["- id: `\(m.id)`", "- date: \(format.date(m.startedAt))",
                     "- duration: \(format.duration(of: m))", "- attendees: \(format.attendees(m.attendees))"]
        if let app = m.sourceApp { lines.append("- source app: \(format.sourceApp(app))") }
        if let folder = m.folder { lines.append("- folder: \(folder)") }
        return lines
    }

    private func label(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .title: "title"
        case .notes: "user's notes"
        case .enhancedNotes: "enhanced notes"
        case .transcript: hit.startOffset.map { "transcript [\(Transcript.timestamp($0))]" } ?? "transcript"
        }
    }

    private func hasText(_ s: String?) -> Bool {
        s.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    /// Keeps the beginning, cutting at a line boundary when one is reasonably close.
    private func truncated(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        var cut = text.index(text.startIndex, offsetBy: maxChars)
        if let newline = text[..<cut].lastIndex(of: "\n"),
           text.distance(from: text.startIndex, to: newline) > maxChars / 2 {
            cut = newline
        }
        let kept = text[..<cut]
        return "\(kept)\n\n[Transcript truncated: showing the first \(kept.count) of \(text.count) characters. Call get_transcript with a larger max_chars to see more.]"
    }
}
