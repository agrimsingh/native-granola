import Combine
import Foundation

/// Wires mic activity + calendar events into `DetectionEngine`, ticking once a second on the main actor.
@MainActor
public final class MeetingDetector: ObservableObject {
    /// Set by the app while a meeting is being recorded; suppresses prompts and enables `onLikelyEnded`.
    @Published public var isRecording = false {
        didSet { if !isRecording { recordingAppBundleID = nil } }
    }
    /// The app the current recording belongs to (e.g. from an accepted ad-hoc suggestion). Inferred if nil.
    public var recordingAppBundleID: String?

    @Published public private(set) var activeMicApps: [MicApp] = []
    @Published public private(set) var upcomingEvents: [CalendarEvent] = []
    @Published public private(set) var hasCalendarAccess: Bool
    @Published public private(set) var isRunning = false
    /// The most recent "likely ended" signal, cleared when recording stops.
    @Published public private(set) var lastEndSignal: MeetingEndSignal?

    public var onSuggestion: ((MeetingSuggestion) -> Void)?
    public var onLikelyEnded: (() -> Void)?

    public let micMonitor: MicActivityMonitor
    public let calendar: CalendarService
    /// Events are fetched from 30 minutes ago to this far ahead.
    public var eventLookahead: TimeInterval = 12 * 3600
    public var eventRefreshInterval: TimeInterval = 60

    public var configuration: DetectionConfiguration {
        get { engine.configuration }
        set { engine.configuration = newValue }
    }

    private var engine: DetectionEngine
    private var dismissedIDs: Set<String> = []
    private var tickTask: Task<Void, Never>?
    private var lastEventRefresh: Date?

    public init(
        configuration: DetectionConfiguration = DetectionConfiguration(),
        micMonitor: MicActivityMonitor = MicActivityMonitor(),
        calendar: CalendarService = CalendarService()
    ) {
        self.engine = DetectionEngine(configuration: configuration)
        self.micMonitor = micMonitor
        self.calendar = calendar
        self.hasCalendarAccess = calendar.hasAccess
    }

    /// Starts mic monitoring, calendar observation and the 1s detection tick. Doesn't prompt for calendar access.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        micMonitor.onChange = { [weak self] apps in
            Task { @MainActor in self?.activeMicApps = apps }
        }
        micMonitor.start()
        calendar.onChange = { [weak self] in
            Task { @MainActor in self?.refreshEvents() }
        }
        refreshEvents()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        tickTask?.cancel()
        tickTask = nil
        micMonitor.stop()
        micMonitor.onChange = nil
        calendar.onChange = nil
        activeMicApps = []
    }

    @discardableResult
    public func requestCalendarAccess() async -> Bool {
        let granted = await calendar.requestAccess()
        hasCalendarAccess = granted
        refreshEvents()
        return granted
    }

    public func refreshEvents(now: Date = Date()) {
        lastEventRefresh = now
        hasCalendarAccess = calendar.hasAccess
        upcomingEvents = calendar.events(from: now.addingTimeInterval(-30 * 60), to: now.addingTimeInterval(eventLookahead))
    }

    /// Never prompt for this suggestion (and its event/app session) again.
    public func dismiss(_ suggestion: MeetingSuggestion) {
        dismissedIDs.insert(suggestion.id)
        if let event = suggestion.event { dismissedIDs.insert(event.occurrenceID) }
    }

    /// Suppress prompts for a suggestion ID, event `id`/`occurrenceID`, or app bundle ID.
    public func dismiss(id: String) {
        dismissedIDs.insert(id)
    }

    /// Runs one detection step. Called automatically every second after `start()`.
    public func tick(now: Date = Date()) {
        if lastEventRefresh.map({ now.timeIntervalSince($0) >= eventRefreshInterval }) ?? true {
            refreshEvents(now: now)
        }
        if !isRecording { lastEndSignal = nil }
        let output = engine.step(DetectionInput(
            now: now,
            micApps: activeMicApps,
            events: upcomingEvents,
            isRecording: isRecording,
            dismissedIDs: dismissedIDs,
            recordingAppBundleID: recordingAppBundleID
        ))
        for suggestion in output.suggestions { onSuggestion?(suggestion) }
        if let signal = output.likelyEnded {
            lastEndSignal = signal
            onLikelyEnded?()
        }
    }
}
