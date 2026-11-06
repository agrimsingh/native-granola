import Foundation
import GranolaCore

/// Maps diarized labels ("Speaker 1") to people's names using the attendee list and cues in the
/// transcript. Only confident answers are kept, and only names that appear in the attendee list or the
/// transcript itself; the user's own name is never assigned (they are "Me").
public struct SpeakerNamer: Sendable {
    public var client: XAIClient
    public var model: String?

    public init(client: XAIClient, model: String? = nil) {
        self.client = client
        self.model = model
    }

    /// Returns label → name for the speakers it could identify, e.g. ["Speaker 2": "Priya Shah"].
    public func nameSpeakers(meeting: Meeting, segments: [TranscriptSegment], userName: String?) async throws
        -> [String: String]
    {
        let labels = Self.speakerLabels(segments)
        guard !labels.isEmpty else { return [:] }
        let messages = Self.messages(meeting: meeting, segments: segments, userName: userName)
        let raw = try await client.complete(messages: messages, model: model, temperature: 0)
        return Self.parse(raw, labels: Set(labels), attendees: meeting.attendees,
                          transcript: segments.map(\.text).joined(separator: "\n"), userName: userName)
    }

    /// Diarized labels in the transcript, in numeric order.
    static func speakerLabels(_ segments: [TranscriptSegment]) -> [String] {
        Set(segments.compactMap(\.speaker).filter { number(of: $0) != nil })
            .sorted { number(of: $0)! < number(of: $1)! }
    }

    private static func number(of label: String) -> Int? {
        label.hasPrefix("Speaker ") ? Int(label.dropFirst("Speaker ".count)) : nil
    }

    static func messages(meeting: Meeting, segments: [TranscriptSegment], userName: String?,
                         maxTranscriptCharacters: Int = 120_000) -> [ChatMessage] {
        let me = (userName?.isEmpty == false) ? userName! : "the user"
        let labels = speakerLabels(segments)
        let attendees = meeting.attendees.compactMap(\.name).filter { !$0.isEmpty }
        let system = """
            You identify speakers in a meeting transcript. "Me" is \(me). The other participants were separated \
            automatically by voice into \(labels.joined(separator: ", ")). Work out which person each label is.

            Evidence that counts:
            - Self-introductions ("Hi, I'm Priya", "This is Marcus from finance").
            - Being addressed by name and then answering: when one line says "Priya, can you…?" or "if Priya \
            has time", Priya is whoever replies to it next, never the person who said the name.
            - Being thanked or greeted by name right after speaking.
            People don't say their own name when talking to others: a label that says a name, or mentions \
            someone in the third person ("Priya will send it"), is NOT that person.

            Rules:
            - Use only names from the attendee list or names that literally appear in the transcript. Never \
            invent or guess names. Never assign \(me), who is "Me".
            - Each name may go to at most one label, and each label to at most one name.
            - Only answer "high" confidence when the evidence is explicit. Leave a label out if unsure.
            - The automatic speaker separation can be wrong; if a label's lines clearly come from different \
            people, leave that label out.
            - Reply with JSON only, no prose outside it: {"analysis": "one or two sentences per name cue: who \
            said it and who replied", "speakers": [{"label": "Speaker 1", "name": "Full Name", "confidence": \
            "high" | "low", "evidence": "short quote"}]}. Use an empty "speakers" list if nobody can be identified.
            """
        let transcript = MeetingContext.truncateMiddle(Transcript.format(segments), limit: maxTranscriptCharacters)
        let user = """
            <attendees>
            \(attendees.isEmpty ? "(unknown)" : attendees.joined(separator: "\n"))
            </attendees>

            <transcript>
            \(transcript)
            </transcript>
            """
        return [.system(system), .user(user)]
    }

    static func parse(_ raw: String, labels: Set<String>, attendees: [Attendee], transcript: String,
                      userName: String?) -> [String: String] {
        let text = MeetingContext.stripCodeFence(raw)
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let json = try? JSONValue.decode(Data(text[open...close].utf8)),
              let items = json["speakers"]?.arrayValue else { return [:] }

        let attendeeNames = attendees.compactMap(\.name).filter { !$0.isEmpty }
        let transcriptWords = Set(words(transcript))
        let userWords = Set(words(userName ?? ""))

        var picked: [String: String] = [:]
        var claims: [String: Int] = [:]
        for item in items {
            guard let label = item["label"]?.stringValue, labels.contains(label),
                  item["confidence"]?.stringValue?.lowercased() == "high",
                  let proposed = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !proposed.isEmpty, picked[label] == nil,
                  let name = canonicalName(proposed, attendees: attendeeNames, transcriptWords: transcriptWords)
            else { continue }
            let nameWords = Set(words(name))
            if !userWords.isEmpty, nameWords == userWords || nameWords.isSubset(of: userWords) { continue }
            picked[label] = name
            claims[name.lowercased(), default: 0] += 1
        }
        return picked.filter { claims[$0.value.lowercased()] == 1 }
    }

    /// The attendee's full name when the proposal matches one attendee (fully or by a unique first or last
    /// name), the proposal itself when every word of it is in the transcript, otherwise nil.
    static func canonicalName(_ proposed: String, attendees: [String], transcriptWords: Set<String>) -> String? {
        let p = words(proposed)
        guard !p.isEmpty else { return nil }
        if let exact = attendees.first(where: { words($0) == p }) { return exact }
        let partial = attendees.filter { Set(p).isSubset(of: Set(words($0))) }
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty, p.allSatisfy(transcriptWords.contains) { return proposed }
        return nil
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
}
