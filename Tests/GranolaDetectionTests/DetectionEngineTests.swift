import Foundation
import GranolaCore
import Testing
@testable import GranolaDetection

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let zoom = MicApp(bundleID: "us.zoom.xos", name: "Zoom", pid: 100)
private let chrome = MicApp(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 200)
private let slack = MicApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", pid: 300)

private func event(
    _ id: String,
    startsIn offset: TimeInterval,
    duration: TimeInterval = 1800,
    attendees: Int = 2,
    allDay: Bool = false,
    url: URL? = nil
) -> CalendarEvent {
    CalendarEvent(
        id: id,
        title: "Event \(id)",
        start: t0.addingTimeInterval(offset),
        end: t0.addingTimeInterval(offset + duration),
        attendees: (0..<attendees).map { Attendee(name: "P\($0)", email: "p\($0)@x.com") },
        conferenceURL: url,
        isAllDay: allDay
    )
}

/// Drives the engine one second at a time with a fake clock.
private struct Harness {
    var engine: DetectionEngine
    var now: TimeInterval = 0
    var micApps: [MicApp] = []
    var events: [CalendarEvent] = []
    var isRecording = false
    var dismissed: Set<String> = []
    var recordingApp: String?

    init(_ configuration: DetectionConfiguration = DetectionConfiguration()) {
        engine = DetectionEngine(configuration: configuration)
    }

    mutating func step(at time: TimeInterval) -> DetectionOutput {
        now = time
        return engine.step(DetectionInput(
            now: t0.addingTimeInterval(time),
            micApps: micApps,
            events: events,
            isRecording: isRecording,
            dismissedIDs: dismissed,
            recordingAppBundleID: recordingApp
        ))
    }

    /// Steps every second from `now + 1` through `end`, collecting outputs keyed by time.
    mutating func run(through end: TimeInterval) -> [(time: TimeInterval, output: DetectionOutput)] {
        var results: [(TimeInterval, DetectionOutput)] = []
        var t = now + 1
        while t <= end {
            results.append((t, step(at: t)))
            t += 1
        }
        return results
    }

    mutating func suggestions(through end: TimeInterval) -> [(time: TimeInterval, suggestion: MeetingSuggestion)] {
        run(through: end).flatMap { r in r.output.suggestions.map { (r.time, $0) } }
    }
}

@Suite struct CalendarPromptTests {
    @Test func promptsOneMinuteBeforeStartOnce() {
        var h = Harness()
        h.events = [event("a", startsIn: 120)]
        _ = h.step(at: 0)
        let shown = h.suggestions(through: 600)
        #expect(shown.count == 1)
        #expect(shown.first?.time == 60)
        #expect(shown.first?.suggestion.id == "calendar:a@\(Int(t0.timeIntervalSince1970) + 120)")
        #expect(shown.first?.suggestion.title == "Event a")
        #expect(shown.first?.suggestion.isCalendar == true)
    }

    @Test func promptsWhenAppStartsLateWithinGracePeriod() {
        var h = Harness()
        h.events = [event("a", startsIn: -240)]
        #expect(h.step(at: 0).suggestions.count == 1)
    }

    @Test func noPromptAfterGracePeriod() {
        var h = Harness()
        h.events = [event("a", startsIn: -301)]
        #expect(h.step(at: 0).suggestions.isEmpty)
    }

    @Test func requiresTwoAttendees() {
        var h = Harness()
        h.events = [event("solo", startsIn: 30, attendees: 1), event("none", startsIn: 30, attendees: 0)]
        #expect(h.step(at: 0).suggestions.isEmpty)
    }

    @Test func organizerCountsTowardAttendees() {
        var h = Harness()
        var e = event("a", startsIn: 30, attendees: 1)
        e.organizer = Attendee(name: "Boss", email: "boss@x.com")
        h.events = [e]
        #expect(h.step(at: 0).suggestions.count == 1)
    }

    @Test func attendeeThresholdIsConfigurable() {
        var h = Harness(DetectionConfiguration(minimumAttendees: 1))
        h.events = [event("solo", startsIn: 30, attendees: 1)]
        #expect(h.step(at: 0).suggestions.count == 1)
    }

    @Test func allDayEventsExcluded() {
        var h = Harness()
        h.events = [event("a", startsIn: 30, duration: 86400, attendees: 5, allDay: true)]
        #expect(h.step(at: 0).suggestions.isEmpty)
    }

    @Test func recordingSuppressesPromptsUntilStopped() {
        var h = Harness()
        h.events = [event("a", startsIn: 60)]
        h.isRecording = true
        #expect(h.suggestions(through: 30).isEmpty)
        h.isRecording = false
        let shown = h.suggestions(through: 40)
        #expect(shown.map(\.time) == [31])
    }

    @Test func dismissedEventIsNotPrompted() {
        var h = Harness()
        let e = event("a", startsIn: 30)
        h.events = [e]
        h.dismissed = [e.id]
        #expect(h.step(at: 0).suggestions.isEmpty)
        h.dismissed = ["calendar:\(e.occurrenceID)"]
        #expect(h.step(at: 1).suggestions.isEmpty)
    }

    @Test func simultaneousEventsShowOnlyClosest() {
        var h = Harness()
        h.events = [event("later", startsIn: 50), event("sooner", startsIn: 10)]
        let out = h.step(at: 0)
        #expect(out.suggestions.map(\.title) == ["Event sooner"])
        #expect(h.suggestions(through: 30).isEmpty)
    }

    @Test func recurringOccurrencesPromptSeparately() {
        var h = Harness()
        h.events = [event("weekly", startsIn: 30)]
        #expect(h.step(at: 0).suggestions.count == 1)
        h.events = [event("weekly", startsIn: 7 * 86400)]
        #expect(h.step(at: 7 * 86400 - 30).suggestions.count == 1)
    }
}

@Suite struct AdHocPromptTests {
    @Test func debouncesThreeSeconds() {
        var h = Harness()
        h.micApps = [zoom]
        let shown = h.suggestions(through: 10)
        #expect(shown.map(\.time) == [4])  // first seen at t=1
        #expect(shown.first?.suggestion.title == "Meeting detected")
        #expect(shown.first?.suggestion.subtitle == "Zoom")
        #expect(shown.first?.suggestion.micApp == zoom)
    }

    @Test func briefMicUseDoesNotPrompt() {
        var h = Harness()
        h.micApps = [zoom]
        _ = h.run(through: 2)
        h.micApps = []
        #expect(h.suggestions(through: 10).isEmpty)
        // A new session must again stay active 3s.
        h.micApps = [zoom]
        #expect(h.suggestions(through: 20).map(\.time) == [14])
    }

    @Test func pollingJitterDoesNotResetSession() {
        var h = Harness()
        h.micApps = [zoom]
        _ = h.step(at: 0)
        h.micApps = []
        _ = h.step(at: 1)  // 1s gap, within tolerance
        h.micApps = [zoom]
        #expect(h.step(at: 2).suggestions.isEmpty)
        #expect(h.step(at: 3).suggestions.count == 1)
    }

    @Test func promptsOncePerMicSession() {
        var h = Harness()
        h.micApps = [zoom]
        #expect(h.suggestions(through: 600).count == 1)
    }

    @Test func repromptsAfterCooldownForNewSession() {
        var h = Harness(DetectionConfiguration(adHocRepromptCooldown: 60))
        h.micApps = [zoom]
        #expect(h.suggestions(through: 10).count == 1)
        h.micApps = []
        _ = h.run(through: 20)
        h.micApps = [zoom]  // back within cooldown (last seen t=10)
        #expect(h.suggestions(through: 40).isEmpty)
        h.micApps = []
        _ = h.run(through: 200)
        h.micApps = [zoom]
        #expect(h.suggestions(through: 210).count == 1)
    }

    @Test func linksToEventWithin15Minutes() {
        var h = Harness()
        let e = event("standup", startsIn: -10 * 60, attendees: 1)
        h.events = [e]
        h.micApps = [zoom]
        let shown = h.suggestions(through: 5)
        #expect(shown.count == 1)
        guard case .adHoc(let app, let linked)? = shown.first?.suggestion.kind else {
            Issue.record("expected ad-hoc suggestion")
            return
        }
        #expect(app == zoom)
        #expect(linked?.id == "standup")
        #expect(shown.first?.suggestion.subtitle == "Event standup")
        #expect(shown.first?.suggestion.title == "Meeting detected")
    }

    @Test func doesNotLinkOutsideWindow() {
        var h = Harness()
        h.events = [event("old", startsIn: -16 * 60, attendees: 1), event("future", startsIn: 6 * 60 + 10, attendees: 1)]
        h.micApps = [zoom]
        let shown = h.suggestions(through: 5)
        #expect(shown.count == 1)
        #expect(shown.first?.suggestion.event == nil)
        #expect(shown.first?.suggestion.subtitle == "Zoom")
    }

    @Test func linksUpcomingEventWithinLookahead() {
        var h = Harness()
        h.events = [event("soon", startsIn: 4 * 60, attendees: 1)]
        h.micApps = [zoom]
        #expect(h.suggestions(through: 5).first?.suggestion.event?.id == "soon")
    }

    @Test func closestEventWins() {
        var h = Harness()
        h.events = [
            event("early", startsIn: -12 * 60, attendees: 1),
            event("close", startsIn: -2 * 60, attendees: 1),
            event("upcoming", startsIn: 4 * 60, attendees: 1),
        ]
        h.micApps = [zoom]
        #expect(h.suggestions(through: 5).first?.suggestion.event?.id == "close")
    }

    @Test func allDayEventsAreNotLinked() {
        var h = Harness()
        h.events = [event("holiday", startsIn: -60, duration: 86400, allDay: true)]
        h.micApps = [zoom]
        #expect(h.suggestions(through: 5).first?.suggestion.event == nil)
    }

    @Test func noDuplicateAfterCalendarPrompt() {
        var h = Harness()
        h.events = [event("sync", startsIn: 60, url: URL(string: "https://zoom.us/j/1"))]
        let calendar = h.suggestions(through: 10)
        #expect(calendar.count == 1)
        #expect(calendar.first?.suggestion.isCalendar == true)
        h.micApps = [zoom]  // user joins the call shortly after
        #expect(h.suggestions(through: 400).isEmpty)
    }

    @Test func calendarPromptSuppressedAfterLinkedAdHocPrompt() {
        var h = Harness()
        h.events = [event("sync", startsIn: 4 * 60)]
        h.micApps = [zoom]
        let shown = h.suggestions(through: 600)
        #expect(shown.count == 1)
        #expect(shown.first?.suggestion.isCalendar == false)
        #expect(shown.first?.suggestion.event?.id == "sync")
    }

    @Test func recordingSuppressesAndMarksSessionHandled() {
        var h = Harness()
        h.micApps = [zoom]
        h.isRecording = true
        #expect(h.suggestions(through: 30).isEmpty)
        h.isRecording = false
        #expect(h.suggestions(through: 60).isEmpty)
    }

    @Test func dismissedAppIsNotPrompted() {
        var h = Harness()
        h.dismissed = [zoom.bundleID]
        h.micApps = [zoom]
        #expect(h.suggestions(through: 10).isEmpty)
    }

    @Test func concurrentAppsProduceOnePromptPreferringMeetingApp() {
        var h = Harness()
        h.micApps = [chrome, zoom]
        let shown = h.suggestions(through: 30)
        #expect(shown.count == 1)
        #expect(shown.first?.suggestion.micApp == zoom)
        // Another app joining the same cluster stays quiet.
        h.micApps = [chrome, zoom, slack]
        #expect(h.suggestions(through: 60).isEmpty)
    }

    @Test func promptTitlesPerApp() {
        var h = Harness()
        h.micApps = [slack]
        #expect(h.suggestions(through: 5).first?.suggestion.title == "Huddle detected")
        var f = Harness()
        f.micApps = [MicApp(bundleID: "com.apple.FaceTime", name: "FaceTime")]
        #expect(f.suggestions(through: 5).first?.suggestion.title == "Call detected")
        #expect(f.engine.configuration.micActivationDelay == 3)
    }

    @Test func thresholdsAreConfigurable() {
        var h = Harness(DetectionConfiguration(micActivationDelay: 10))
        h.micApps = [zoom]
        #expect(h.suggestions(through: 30).map(\.time) == [11])
    }

    @Test func disablingAdHocPrompts() {
        var h = Harness(DetectionConfiguration(adHocPromptsEnabled: false))
        h.micApps = [zoom]
        #expect(h.suggestions(through: 30).isEmpty)
    }
}

@Suite struct LikelyEndedTests {
    @Test func signalsAfterTriggerInactiveFor20Seconds() {
        var h = Harness()
        h.micApps = [zoom]
        _ = h.run(through: 5)
        h.isRecording = true
        _ = h.run(through: 100)
        h.micApps = []  // last seen at t=100
        let ended = h.run(through: 200).filter { $0.output.likelyEnded != nil }
        #expect(ended.map(\.time) == [120])
        #expect(ended.first?.output.likelyEnded?.app == zoom)
        #expect(ended.first?.output.likelyEnded?.lastActive == t0.addingTimeInterval(100))
    }

    @Test func briefDropDoesNotSignal() {
        var h = Harness()
        h.micApps = [zoom]
        h.isRecording = true
        _ = h.run(through: 10)
        h.micApps = []
        _ = h.run(through: 25)
        h.micApps = [zoom]
        #expect(h.run(through: 100).allSatisfy { $0.output.likelyEnded == nil })
    }

    @Test func signalsAgainAfterTriggerReturnsAndLeaves() {
        var h = Harness()
        h.micApps = [zoom]
        h.isRecording = true
        _ = h.run(through: 10)
        h.micApps = []
        #expect(h.run(through: 50).filter { $0.output.likelyEnded != nil }.map(\.time) == [30])
        h.micApps = [zoom]
        _ = h.run(through: 60)
        h.micApps = []
        #expect(h.run(through: 100).filter { $0.output.likelyEnded != nil }.map(\.time) == [80])
    }

    @Test func otherAppsDoNotKeepRecordingAlive() {
        var h = Harness()
        h.micApps = [zoom]
        h.isRecording = true
        h.recordingApp = zoom.bundleID
        _ = h.run(through: 10)
        h.micApps = [chrome]
        #expect(h.run(through: 40).filter { $0.output.likelyEnded != nil }.map(\.time) == [30])
    }

    @Test func triggerAdoptedWhenMicStartsDuringRecording() {
        var h = Harness()
        h.isRecording = true  // user took notes from a calendar prompt before joining
        _ = h.run(through: 30)
        h.micApps = [zoom]
        _ = h.run(through: 60)
        h.micApps = []
        #expect(h.run(through: 100).filter { $0.output.likelyEnded != nil }.map(\.time) == [80])
    }

    @Test func prefersPromptedAppAsTrigger() {
        var h = Harness()
        h.micApps = [chrome]
        _ = h.run(through: 1)
        h.micApps = [chrome, zoom]
        _ = h.run(through: 20)  // chrome was prompted at t=4; zoom joined the cluster quietly
        h.isRecording = true
        _ = h.run(through: 30)
        h.micApps = [zoom]
        let ended = h.run(through: 60).compactMap(\.output.likelyEnded)
        #expect(ended.map(\.app) == [chrome])
    }

    @Test func noSignalWithoutRecordingOrMicActivity() {
        var h = Harness()
        h.micApps = [zoom]
        _ = h.run(through: 10)
        h.micApps = []
        #expect(h.run(through: 60).allSatisfy { $0.output.likelyEnded == nil })
        h.isRecording = true
        #expect(h.run(through: 120).allSatisfy { $0.output.likelyEnded == nil })
    }

    @Test func delayIsConfigurable() {
        var h = Harness(DetectionConfiguration(likelyEndedDelay: 5))
        h.micApps = [zoom]
        h.isRecording = true
        _ = h.run(through: 10)
        h.micApps = []
        #expect(h.run(through: 30).filter { $0.output.likelyEnded != nil }.map(\.time) == [15])
    }
}

@Suite struct SuggestionTests {
    @Test func meetingTitles() {
        let adHoc = MeetingSuggestion.adHoc(slack, linkedEvent: nil, sessionStart: t0, detectedAt: t0)
        #expect(adHoc.meetingTitle == "Slack huddle")
        #expect(adHoc.conferenceURL == nil)
        let e = event("x", startsIn: 0, url: URL(string: "https://meet.google.com/abc-defg-hij"))
        let linked = MeetingSuggestion.adHoc(chrome, linkedEvent: e, sessionStart: t0, detectedAt: t0)
        #expect(linked.meetingTitle == "Event x")
        #expect(linked.conferenceURL?.host == "meet.google.com")
        #expect(linked.attendees.count == 2)
    }

    @Test func relativeTimeLabels() {
        #expect(PromptTimeLabel.relative(start: t0.addingTimeInterval(60), now: t0) == "Starts in 1 min")
        #expect(PromptTimeLabel.relative(start: t0.addingTimeInterval(10), now: t0) == "Starting now")
        #expect(PromptTimeLabel.relative(start: t0.addingTimeInterval(-180), now: t0) == "Started 3 min ago")
        #expect(PromptTimeLabel.relative(start: t0, now: t0, startedWord: "Detected") == "Detected just now")
    }
}
