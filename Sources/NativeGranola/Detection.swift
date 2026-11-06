import AppKit
import GranolaCore
import GranolaDetection
import SwiftUI

/// Connects meeting detection (calendar + mic activity) to recording.
@MainActor
final class DetectionCoordinator {
    static let shared = DetectionCoordinator()
    let detector = MeetingDetector()
    var openMainWindow: (() -> Void)?

    private init() {}

    func start() {
        let state = AppState.shared
        detector.onSuggestion = { [weak self] suggestion in
            guard let self, !state.recorder.isRecording else { return }
            MeetingPromptPanel.show(suggestion, onTakeNotes: { suggestion in
                Task { await self.takeNotes(for: suggestion) }
            }, onDismiss: { suggestion in
                self.detector.dismiss(suggestion)
            })
        }
        detector.onLikelyEnded = {
            guard Preferences.autoStop, state.recorder.isRecording else { return }
            Task { await state.stopMeeting() }
        }
        detector.start()
        if CalendarService.authorizationStatus == .notDetermined {
            Task { await detector.requestCalendarAccess() }
        }
    }

    func takeNotes(for suggestion: MeetingSuggestion) async {
        let event = suggestion.event
        var app: MicApp?
        if case let .adHoc(micApp, _) = suggestion.kind { app = micApp }
        await startMeeting(event: event, app: app, title: suggestion.meetingTitle)
    }

    func startMeeting(event: CalendarEvent?, app: MicApp? = nil, title: String? = nil) async {
        let state = AppState.shared
        await state.startMeeting(title: event?.displayTitle ?? title ?? app.map { "\($0.name) call" },
                                 attendees: event?.attendees ?? [],
                                 calendarEventID: event?.occurrenceID,
                                 sourceApp: app?.bundleID)
        detector.recordingAppBundleID = app?.bundleID
        openMainWindow?()
    }

    /// Keep the detector's view of recording in sync so it suppresses prompts and watches for the end.
    func recordingChanged(_ isRecording: Bool) {
        detector.isRecording = isRecording
        if isRecording { MeetingPromptPanel.dismiss() }
    }
}

/// Upcoming calendar events in the menu bar popover.
struct UpcomingMeetingsSection: View {
    @ObservedObject var detector: MeetingDetector
    @Environment(AppState.self) private var state

    var body: some View {
        let upcoming = detector.upcomingEvents
            .filter { !$0.isAllDay && $0.end > Date() && Calendar.current.isDateInToday($0.start) }
            .prefix(4)
        if !detector.hasCalendarAccess {
            Button {
                Task { await detector.requestCalendarAccess() }
            } label: {
                Label("Connect calendar", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(PillButtonStyle(kind: .soft, compact: true))
        } else if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                MenuSectionTitle("Coming up")
                ForEach(Array(upcoming)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.displayTitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text("\(event.participantCount) people")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer(minLength: 6)
                        if !state.recorder.isRecording {
                            Button("Start") {
                                Task { await DetectionCoordinator.shared.startMeeting(event: event) }
                            }
                            .buttonStyle(PillButtonStyle(kind: .soft, compact: true))
                        }
                    }
                }
            }
        }
    }
}
