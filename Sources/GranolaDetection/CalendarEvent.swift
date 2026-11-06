import Foundation
import GranolaCore

public struct CalendarEvent: Codable, Sendable, Hashable, Identifiable {
    /// `calendarItemExternalIdentifier` (stable across devices) or `eventIdentifier`.
    /// Shared by all occurrences of a recurring event; see `occurrenceID`.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [Attendee]
    public var organizer: Attendee?
    public var conferenceURL: URL?
    public var notes: String?
    public var location: String?
    public var calendarTitle: String?
    public var isAllDay: Bool

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [Attendee] = [],
        organizer: Attendee? = nil,
        conferenceURL: URL? = nil,
        notes: String? = nil,
        location: String? = nil,
        calendarTitle: String? = nil,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.organizer = organizer
        self.conferenceURL = conferenceURL
        self.notes = notes
        self.location = location
        self.calendarTitle = calendarTitle
        self.isAllDay = isAllDay
    }

    /// Unique per occurrence of a recurring event.
    public var occurrenceID: String { "\(id)@\(Int(start.timeIntervalSince1970))" }

    /// Distinct people on the event: attendees plus the organizer if not already listed.
    public var participantCount: Int {
        var keys = Set<String>()
        var anonymous = 0
        for person in attendees + [organizer].compactMap({ $0 }) {
            if let key = (person.email ?? person.name)?.lowercased() { keys.insert(key) } else { anonymous += 1 }
        }
        return keys.count + anonymous
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }
}

public enum ConferenceProvider: String, Codable, Sendable, CaseIterable {
    case zoom, googleMeet, teams, webex, slack, chime, goTo, jitsi, whereby

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .slack: "Slack"
        case .chime: "Amazon Chime"
        case .goTo: "GoTo Meeting"
        case .jitsi: "Jitsi Meet"
        case .whereby: "Whereby"
        }
    }
}

/// Finds video-conference join links in event URLs, locations and notes.
public enum ConferenceLinkExtractor {
    private static let tail = #"[^\s<>"'\])]*"#

    private static let patterns: [(ConferenceProvider, NSRegularExpression)] = {
        let raw: [(ConferenceProvider, String)] = [
            (.zoom, #"(?:https?://)?(?:[a-z0-9-]+\.)*zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s|wc(?:/join)?)/"# + tail),
            (.zoom, #"zoommtg://"# + tail),
            (.googleMeet, #"(?:https?://)?meet\.google\.com/(?:[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}|lookup/[a-z0-9_-]+)"# + tail),
            (.teams, #"(?:https?://)?teams\.microsoft\.com/(?:l/meetup-join|meet)/"# + tail),
            (.teams, #"(?:https?://)?teams\.live\.com/meet/"# + tail),
            (.webex, #"(?:https?://)?(?:[a-z0-9-]+\.)+webex\.com/(?:meet|join|[a-z0-9-]+/j\.php|wbxmjs|webappng)"# + tail),
            (.slack, #"(?:https?://)?app\.slack\.com/huddle/"# + tail),
            (.chime, #"(?:https?://)?chime\.aws/\d+"# + tail),
            (.goTo, #"(?:https?://)?(?:global\.gotomeeting\.com/join|meet\.goto\.com|app\.goto\.com/meeting)/"# + tail),
            (.jitsi, #"(?:https?://)?meet\.jit\.si/"# + tail),
            (.whereby, #"(?:https?://)?whereby\.com/"# + tail),
        ]
        return raw.map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }
    }()

    /// The join link for an event: `url` if it's a conference link, else the first link in `location`, then `notes`.
    public static func conferenceURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let found = firstURL(in: url.absoluteString) { return found }
        for text in [location, notes] {
            if let text, let found = firstURL(in: text) { return found }
        }
        return nil
    }

    /// The earliest conference link in `text`, scheme added if missing and trailing punctuation trimmed.
    public static func firstURL(in text: String) -> URL? {
        firstMatch(in: text)?.url
    }

    public static func provider(for url: URL) -> ConferenceProvider? {
        firstMatch(in: url.absoluteString)?.provider
    }

    private static func firstMatch(in text: String) -> (provider: ConferenceProvider, url: URL)? {
        let range = NSRange(text.startIndex..., in: text)
        var best: (location: Int, provider: ConferenceProvider, string: String)?
        for (provider, regex) in patterns {
            guard let match = regex.firstMatch(in: text, range: range),
                  let r = Range(match.range, in: text) else { continue }
            if best == nil || match.range.location < best!.location {
                best = (match.range.location, provider, String(text[r]))
            }
        }
        guard let best else { return nil }
        var string = best.string
        while let last = string.last, ".,;:!?".contains(last) { string.removeLast() }
        if !string.lowercased().hasPrefix("http") && !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string) else { return nil }
        return (best.provider, url)
    }
}
