import Foundation
import GranolaCore

public struct MeetingSuggestion: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case calendar(CalendarEvent)
        case adHoc(MicApp, linkedEvent: CalendarEvent?)
    }

    /// `calendar:<occurrenceID>` or `adhoc:<bundleID>:<mic session start>`.
    public var id: String
    public var kind: Kind
    /// Event title for calendar prompts; "Meeting detected" / "Huddle detected" / "Call detected" for ad-hoc ones.
    public var title: String
    /// Time range for calendar prompts; linked event title or app name for ad-hoc ones.
    public var subtitle: String
    public var detectedAt: Date

    public init(id: String, kind: Kind, title: String, subtitle: String, detectedAt: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detectedAt = detectedAt
    }

    public static func calendar(_ event: CalendarEvent, detectedAt: Date) -> MeetingSuggestion {
        MeetingSuggestion(
            id: "calendar:\(event.occurrenceID)",
            kind: .calendar(event),
            title: event.displayTitle,
            subtitle: timeRange(event),
            detectedAt: detectedAt
        )
    }

    public static func adHoc(_ app: MicApp, linkedEvent: CalendarEvent?, sessionStart: Date, detectedAt: Date) -> MeetingSuggestion {
        MeetingSuggestion(
            id: "adhoc:\(app.bundleID):\(Int(sessionStart.timeIntervalSince1970))",
            kind: .adHoc(app, linkedEvent: linkedEvent),
            title: AppIdentity.promptTitle(forBundleID: app.bundleID),
            subtitle: linkedEvent?.displayTitle ?? app.name,
            detectedAt: detectedAt
        )
    }

    /// The calendar event, or the event an ad-hoc call was linked to.
    public var event: CalendarEvent? {
        switch kind {
        case .calendar(let event): event
        case .adHoc(_, let linked): linked
        }
    }

    public var micApp: MicApp? {
        if case .adHoc(let app, _) = kind { return app }
        return nil
    }

    public var isCalendar: Bool {
        if case .calendar = kind { return true }
        return false
    }

    public var conferenceURL: URL? { event?.conferenceURL }

    public var attendees: [Attendee] { event?.attendees ?? [] }

    /// A title for the meeting record if the user takes notes.
    public var meetingTitle: String {
        if let event { return event.displayTitle }
        guard let app = micApp else { return "Meeting" }
        return "\(app.name) \(AppIdentity.meetingNoun(forBundleID: app.bundleID))"
    }

    static func timeRange(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: event.start, to: event.end)
    }
}

/// The app that triggered a recording has stopped using the mic.
public struct MeetingEndSignal: Sendable, Hashable {
    public var app: MicApp
    public var lastActive: Date

    public init(app: MicApp, lastActive: Date) {
        self.app = app
        self.lastActive = lastActive
    }
}

public struct DetectionConfiguration: Sendable, Hashable {
    /// Calendar prompts open this long before an event's start...
    public var calendarLeadTime: TimeInterval
    /// ...and stay eligible until this long after it.
    public var calendarGracePeriod: TimeInterval
    public var minimumAttendees: Int
    /// A mic app must be active continuously this long before an ad-hoc prompt.
    public var micActivationDelay: TimeInterval
    /// Absences up to this long (polling jitter) don't end a mic session.
    public var micGapTolerance: TimeInterval
    /// An app that was already prompted/recorded isn't prompted again if it reappears within this long.
    public var adHocRepromptCooldown: TimeInterval
    /// Ad-hoc prompts link to the event whose start is in `[now - linkLookback, now + linkLookahead]`.
    public var linkLookback: TimeInterval
    public var linkLookahead: TimeInterval
    /// While recording, the triggering app being inactive this long emits a "likely ended" signal.
    public var likelyEndedDelay: TimeInterval
    public var calendarPromptsEnabled: Bool
    public var adHocPromptsEnabled: Bool

    public init(
        calendarLeadTime: TimeInterval = 60,
        calendarGracePeriod: TimeInterval = 5 * 60,
        minimumAttendees: Int = 2,
        micActivationDelay: TimeInterval = 3,
        micGapTolerance: TimeInterval = 2,
        adHocRepromptCooldown: TimeInterval = 5 * 60,
        linkLookback: TimeInterval = 15 * 60,
        linkLookahead: TimeInterval = 5 * 60,
        likelyEndedDelay: TimeInterval = 20,
        calendarPromptsEnabled: Bool = true,
        adHocPromptsEnabled: Bool = true
    ) {
        self.calendarLeadTime = calendarLeadTime
        self.calendarGracePeriod = calendarGracePeriod
        self.minimumAttendees = minimumAttendees
        self.micActivationDelay = micActivationDelay
        self.micGapTolerance = micGapTolerance
        self.adHocRepromptCooldown = adHocRepromptCooldown
        self.linkLookback = linkLookback
        self.linkLookahead = linkLookahead
        self.likelyEndedDelay = likelyEndedDelay
        self.calendarPromptsEnabled = calendarPromptsEnabled
        self.adHocPromptsEnabled = adHocPromptsEnabled
    }
}

public struct DetectionInput: Sendable {
    public var now: Date
    public var micApps: [MicApp]
    public var events: [CalendarEvent]
    public var isRecording: Bool
    /// Suppresses prompts matching a suggestion ID, event `id`/`occurrenceID`, or app bundle ID.
    public var dismissedIDs: Set<String>
    /// The app the current recording belongs to, if known. Otherwise the engine infers it.
    public var recordingAppBundleID: String?

    public init(
        now: Date,
        micApps: [MicApp] = [],
        events: [CalendarEvent] = [],
        isRecording: Bool = false,
        dismissedIDs: Set<String> = [],
        recordingAppBundleID: String? = nil
    ) {
        self.now = now
        self.micApps = micApps
        self.events = events
        self.isRecording = isRecording
        self.dismissedIDs = dismissedIDs
        self.recordingAppBundleID = recordingAppBundleID
    }
}

public struct DetectionOutput: Sendable, Hashable {
    public var suggestions: [MeetingSuggestion] = []
    public var likelyEnded: MeetingEndSignal?

    public init(suggestions: [MeetingSuggestion] = [], likelyEnded: MeetingEndSignal? = nil) {
        self.suggestions = suggestions
        self.likelyEnded = likelyEnded
    }
}

/// Deterministic meeting-detection state machine. Feed it a `DetectionInput` every tick (~1s);
/// it has no clocks or I/O of its own.
public struct DetectionEngine: Sendable {
    public var configuration: DetectionConfiguration

    private struct MicSession {
        var app: MicApp
        var start: Date
        var lastSeen: Date
        var handled: Bool
    }

    private struct RecordingTrigger {
        var app: MicApp
        var lastSeen: Date?
        var signaled: Bool
    }

    private var sessions: [String: MicSession] = [:]
    /// occurrenceID -> event start, for events already prompted (by calendar or linked ad-hoc prompt).
    private var promptedEvents: [String: Date] = [:]
    /// bundleID -> last time seen while handled, for the re-prompt cooldown.
    private var recentlyHandledApps: [String: Date] = [:]
    private var lastAdHocBundleID: String?
    private var wasRecording = false
    private var trigger: RecordingTrigger?

    public init(configuration: DetectionConfiguration = DetectionConfiguration()) {
        self.configuration = configuration
    }

    public mutating func step(_ input: DetectionInput) -> DetectionOutput {
        let now = input.now
        var output = DetectionOutput()
        var active: [String: MicApp] = [:]
        for app in input.micApps where active[app.bundleID] == nil { active[app.bundleID] = app }

        updateSessions(active: active, now: now)

        if input.isRecording {
            output.likelyEnded = updateRecording(input, active: active)
        } else {
            trigger = nil
            if configuration.calendarPromptsEnabled, let suggestion = calendarPrompt(input) {
                output.suggestions.append(suggestion)
            }
            if configuration.adHocPromptsEnabled,
               let suggestion = adHocPrompt(input, active: active, suppressed: !output.suggestions.isEmpty) {
                output.suggestions.append(suggestion)
            }
        }
        wasRecording = input.isRecording

        for (id, session) in sessions where session.handled { recentlyHandledApps[id] = session.lastSeen }
        prune(now: now)
        return output
    }

    // MARK: - Mic sessions

    private mutating func updateSessions(active: [String: MicApp], now: Date) {
        for (id, app) in active {
            if var session = sessions[id], now.timeIntervalSince(session.lastSeen) <= configuration.micGapTolerance {
                session.app = app
                session.lastSeen = now
                sessions[id] = session
            } else {
                let cooling = recentlyHandledApps[id].map { now.timeIntervalSince($0) <= configuration.adHocRepromptCooldown } ?? false
                sessions[id] = MicSession(app: app, start: now, lastSeen: now, handled: cooling)
            }
        }
        sessions = sessions.filter { id, session in
            active[id] != nil || now.timeIntervalSince(session.lastSeen) <= configuration.micGapTolerance
        }
    }

    // MARK: - Recording

    private mutating func updateRecording(_ input: DetectionInput, active: [String: MicApp]) -> MeetingEndSignal? {
        let now = input.now
        for id in sessions.keys { sessions[id]?.handled = true }

        if let override = input.recordingAppBundleID.map(AppIdentity.normalizedBundleID), trigger?.app.bundleID != override {
            let app = active[override] ?? sessions[override]?.app ?? MicApp(bundleID: override, name: AppIdentity.friendlyNames[override] ?? override)
            trigger = RecordingTrigger(app: app, lastSeen: active[override] != nil ? now : nil, signaled: false)
        } else if trigger == nil {
            let preferred = (!wasRecording ? lastAdHocBundleID : nil).flatMap { active[$0] }
            if let app = preferred ?? Self.prioritized(Array(active.values), sessions: sessions).first {
                trigger = RecordingTrigger(app: app, lastSeen: now, signaled: false)
            }
        }

        guard var current = trigger else { return nil }
        defer { trigger = current }
        if let app = active[current.app.bundleID] {
            current.app = app
            current.lastSeen = now
            current.signaled = false
            return nil
        }
        guard let lastSeen = current.lastSeen, !current.signaled,
              now.timeIntervalSince(lastSeen) >= configuration.likelyEndedDelay else { return nil }
        current.signaled = true
        return MeetingEndSignal(app: current.app, lastActive: lastSeen)
    }

    // MARK: - Prompts

    private mutating func calendarPrompt(_ input: DetectionInput) -> MeetingSuggestion? {
        let now = input.now
        let due = input.events.filter { event in
            !event.isAllDay
                && event.participantCount >= configuration.minimumAttendees
                && now >= event.start.addingTimeInterval(-configuration.calendarLeadTime)
                && now <= event.start.addingTimeInterval(configuration.calendarGracePeriod)
                && promptedEvents[event.occurrenceID] == nil
                && !Self.isDismissed(event, input.dismissedIDs)
        }
        guard let pick = Self.closest(due, to: now) else { return nil }
        for event in due { promptedEvents[event.occurrenceID] = event.start }
        return MeetingSuggestion.calendar(pick, detectedAt: now)
    }

    private mutating func adHocPrompt(_ input: DetectionInput, active: [String: MicApp], suppressed: Bool) -> MeetingSuggestion? {
        let now = input.now
        let ready = sessions.values.filter { session in
            !session.handled && active[session.app.bundleID] != nil
                && now.timeIntervalSince(session.start) >= configuration.micActivationDelay
        }
        guard !ready.isEmpty else { return nil }
        // One prompt per cluster of concurrent mic activity: if any active app was already prompted, stay quiet.
        var blocked = suppressed || sessions.values.contains { $0.handled && active[$0.app.bundleID] != nil }
        var result: MeetingSuggestion?

        for app in Self.prioritized(ready.map(\.app), sessions: sessions) {
            let session = sessions[app.bundleID]!
            sessions[app.bundleID]?.handled = true
            if blocked || input.dismissedIDs.contains(app.bundleID) { continue }
            let linked = linkedEvent(input.events, now: now)
            if let linked, promptedEvents[linked.occurrenceID] != nil || Self.isDismissed(linked, input.dismissedIDs) {
                blocked = true
                continue
            }
            let suggestion = MeetingSuggestion.adHoc(app, linkedEvent: linked, sessionStart: session.start, detectedAt: now)
            if input.dismissedIDs.contains(suggestion.id) { continue }
            if let linked { promptedEvents[linked.occurrenceID] = linked.start }
            lastAdHocBundleID = app.bundleID
            result = suggestion
            blocked = true
        }
        return result
    }

    /// The non-all-day event whose start is closest to `now` within the link window.
    func linkedEvent(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let candidates = events.filter { event in
            !event.isAllDay
                && event.start >= now.addingTimeInterval(-configuration.linkLookback)
                && event.start <= now.addingTimeInterval(configuration.linkLookahead)
        }
        return Self.closest(candidates, to: now)
    }

    // MARK: - Helpers

    private static func closest(_ events: [CalendarEvent], to now: Date) -> CalendarEvent? {
        events.min { a, b in
            let da = abs(a.start.timeIntervalSince(now)), db = abs(b.start.timeIntervalSince(now))
            if da != db { return da < db }
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
    }

    private static func isDismissed(_ event: CalendarEvent, _ dismissed: Set<String>) -> Bool {
        dismissed.contains(event.id) || dismissed.contains(event.occurrenceID) || dismissed.contains("calendar:\(event.occurrenceID)")
    }

    /// Dedicated meeting apps first, then browsers, then anything else; earlier sessions first within a group.
    private static func prioritized(_ apps: [MicApp], sessions: [String: MicSession]) -> [MicApp] {
        func rank(_ app: MicApp) -> Int {
            AppIdentity.isKnownMeetingApp(app.bundleID) ? 0 : AppIdentity.isBrowser(app.bundleID) ? 1 : 2
        }
        return apps.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let sa = sessions[a.bundleID]?.start ?? .distantFuture, sb = sessions[b.bundleID]?.start ?? .distantFuture
            if sa != sb { return sa < sb }
            return a.bundleID < b.bundleID
        }
    }

    private mutating func prune(now: Date) {
        promptedEvents = promptedEvents.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        recentlyHandledApps = recentlyHandledApps.filter { now.timeIntervalSince($0.value) <= configuration.adHocRepromptCooldown }
    }
}
