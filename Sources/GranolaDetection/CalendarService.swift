import EventKit
import Foundation
import GranolaCore

/// Reads events from the system calendar store (iCloud, Google/Exchange accounts added in Internet Accounts, ...).
public final class CalendarService: @unchecked Sendable {
    public let store: EKEventStore
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var changeHandler: (@Sendable () -> Void)?

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil
        ) { [weak self] _ in
            self?.lock.withLock { self?.changeHandler }?()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Called (on an arbitrary thread) when the calendar database changes.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public static var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    public var hasAccess: Bool { Self.authorizationStatus == .fullAccess }

    /// Prompts for full calendar access if undetermined. Needs `NSCalendarsFullAccessUsageDescription` in Info.plist.
    public func requestAccess() async -> Bool {
        if hasAccess { return true }
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted { store.reset() }
            return granted
        } catch {
            return false
        }
    }

    /// Events overlapping `[from, to]`, sorted by start. Skips cancelled events and ones the user declined.
    public func events(from: Date, to: Date, includeDeclined: Bool = false) -> [CalendarEvent] {
        guard hasAccess, to > from else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                guard event.status != .canceled else { return false }
                if includeDeclined { return true }
                return !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .map(Self.makeEvent)
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Events starting within the next `interval` seconds, plus those already in progress.
    public func upcomingEvents(within interval: TimeInterval, now: Date = Date()) -> [CalendarEvent] {
        events(from: now, to: now.addingTimeInterval(interval))
    }

    static func makeEvent(_ event: EKEvent) -> CalendarEvent {
        let participants = (event.attendees ?? []).filter { $0.participantType != .room && $0.participantType != .resource }
        let id = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        return CalendarEvent(
            id: id,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            attendees: participants.map(attendee),
            organizer: event.organizer.map(attendee),
            conferenceURL: ConferenceLinkExtractor.conferenceURL(
                url: event.url, location: event.location, notes: event.hasNotes ? event.notes : nil
            ),
            notes: event.notes,
            location: event.location,
            calendarTitle: event.calendar?.title,
            isAllDay: event.isAllDay
        )
    }

    static func attendee(_ participant: EKParticipant) -> Attendee {
        let email = email(from: participant.url)
        var name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.isEmpty == true || name?.lowercased() == email?.lowercased() { name = nil }
        return Attendee(name: name, email: email)
    }

    /// Extracts the address from a `mailto:` participant URL (ignores `urn:uuid:` etc.).
    public static func email(from url: URL) -> String? {
        let string = url.absoluteString
        guard string.lowercased().hasPrefix("mailto:") else { return nil }
        var address = String(string.dropFirst("mailto:".count))
        if let query = address.firstIndex(of: "?") { address = String(address[..<query]) }
        address = address.removingPercentEncoding ?? address
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.contains("@") ? address : nil
    }
}
