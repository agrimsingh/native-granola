import Foundation

public struct Attendee: Codable, Sendable, Hashable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }

    public var displayName: String { name ?? email ?? "Unknown" }
}

public struct Meeting: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var calendarEventID: String?
    public var attendees: [Attendee]
    /// Bundle ID of the app that triggered the meeting (e.g. us.zoom.xos), if known.
    public var sourceApp: String?
    /// The user's own notes, typed during the meeting (markdown).
    public var rawNotes: String
    /// AI-generated notes (markdown), produced after the meeting ends.
    public var enhancedNotes: String?
    public var templateID: String?
    public var folder: String?
    public var notionPageURL: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        calendarEventID: String? = nil,
        attendees: [Attendee] = [],
        sourceApp: String? = nil,
        rawNotes: String = "",
        enhancedNotes: String? = nil,
        templateID: String? = nil,
        folder: String? = nil,
        notionPageURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.calendarEventID = calendarEventID
        self.attendees = attendees
        self.sourceApp = sourceApp
        self.rawNotes = rawNotes
        self.enhancedNotes = enhancedNotes
        self.templateID = templateID
        self.folder = folder
        self.notionPageURL = notionPageURL
    }

    public var isInProgress: Bool { endedAt == nil }
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    /// Who the computer's audio belongs to when no single speaker has been identified: the one other
    /// attendee's name, "Priya, Marcus +2" for a group, or "Other side" when the attendees are unknown.
    public func otherSideLabel(userName: String?) -> String {
        let me = Set(Self.words(userName ?? ""))
        let others = attendees.filter { attendee in
            let words = Set(Self.words(attendee.name ?? ""))
            return me.isEmpty || words.isEmpty || !(words.isSubset(of: me) || me.isSubset(of: words))
        }
        switch others.count {
        case 0: return "Other side"
        case 1: return others[0].displayName
        default:
            let first = others.map { $0.name?.split(separator: " ").first.map(String.init) ?? $0.displayName }
            let shown = first.prefix(2).joined(separator: ", ")
            return first.count > 2 ? "\(shown) +\(first.count - 2)" : shown
        }
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

/// Which capture stream a segment came from. This is how "me" vs "them" is decided.
public enum TranscriptSource: String, Codable, Sendable, Hashable, CaseIterable {
    case microphone
    case system

    public var speakerLabel: String { self == .microphone ? "Me" : "Them" }
}

public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var meetingID: String
    public var source: TranscriptSource
    public var text: String
    /// Seconds since the meeting's `startedAt`.
    public var startOffset: TimeInterval
    public var endOffset: TimeInterval
    /// Who spoke, when known beyond the Me/Them split: "Speaker 1", or a name like "Priya Shah".
    public var speaker: String?

    public init(
        id: String = UUID().uuidString,
        meetingID: String,
        source: TranscriptSource,
        text: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speaker: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.speaker = speaker
    }

    /// The label to show: the identified speaker if there is one, otherwise Me or Them.
    public var displaySpeaker: String { speaker ?? source.speakerLabel }

    /// The label for people reading the transcript: the identified speaker, "Me", or `otherSide`.
    public func displaySpeaker(otherSide: String) -> String {
        speaker ?? (source == .microphone ? source.speakerLabel : otherSide)
    }
}

public struct SearchHit: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case title, notes, enhancedNotes, transcript }
    public var meetingID: String
    public var meetingTitle: String
    public var meetingStartedAt: Date
    public var kind: Kind
    public var snippet: String
    /// Offset into the meeting, for transcript hits.
    public var startOffset: TimeInterval?
}

public enum Transcript {
    /// Plain-text transcript with timestamps and Me/Them labels, merging both sources in time order.
    /// `otherSide` replaces "Them" for unidentified remote speakers.
    public static func format(_ segments: [TranscriptSegment], otherSide: String? = nil) -> String {
        segments
            .sorted { $0.startOffset < $1.startOffset }
            .map { "[\(timestamp($0.startOffset))] \(otherSide.map($0.displaySpeaker(otherSide:)) ?? $0.displaySpeaker): \($0.text)" }
            .joined(separator: "\n")
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
