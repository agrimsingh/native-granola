import GranolaAudio
import GranolaCore
import SwiftUI

typealias GranolaAudioRecorderRef = MeetingRecorder

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if state.recorder.isRecording, let meeting = state.recorder.meeting {
                RecordingCard(meeting: meeting, recorder: state.recorder)
            } else {
                Button {
                    Task {
                        await state.startMeeting()
                        showMainWindow(openWindow)
                    }
                } label: {
                    Label("Start new note", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(state.recorder.state == .preparing)
            }
            if let error = state.lastError {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
                    Text(error).foregroundStyle(Theme.ink).lineLimit(3)
                }
                .font(.system(size: 12))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            ExtraMenuSections()
            recent
            VStack(spacing: 10) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                footer
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.canvas)
        .tint(Theme.accentFill)
    }

    private var header: some View {
        HStack {
            Text("Native Granola")
                .font(Theme.serif(18))
                .tracking(-0.2)
                .foregroundStyle(Theme.ink)
            Spacer()
            if state.recorder.state == .preparing {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var recent: some View {
        let recent = state.meetings.filter { !$0.isInProgress }.prefix(5)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                MenuSectionTitle("Recent")
                VStack(spacing: 0) {
                    ForEach(Array(recent)) { meeting in
                        Button {
                            state.selectedMeetingID = meeting.id
                            showMainWindow(openWindow)
                        } label: {
                            HStack(spacing: 8) {
                                Text(meeting.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            .hoverHighlight()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button("Open notes") { showMainWindow(openWindow) }
                .buttonStyle(PillButtonStyle(kind: .soft, compact: true))
            Spacer()
            Button {
                NSApp.activate()
                openSettings()
            } label: { Image(systemName: "gearshape").frame(width: 26, height: 22) }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power").frame(width: 26, height: 22) }
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.inkSecondary)
    }
}

struct MenuSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.inkSecondary)
    }
}

struct ExtraMenuSections: View {
    var body: some View {
        UpcomingMeetingsSection(detector: DetectionCoordinator.shared.detector)
    }
}

struct RecordingCard: View {
    let meeting: Meeting
    let recorder: MeetingRecorder
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RecordingDot()
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                ElapsedTime(since: meeting.startedAt)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
            }
            HStack(spacing: 18) {
                LevelMeter(label: "Me", level: recorder.levels[.microphone] ?? 0)
                LevelMeter(label: "Them", level: recorder.levels[.system] ?? 0)
            }
            if let last = recorder.volatileText.values.first ?? recorder.segments.last?.text {
                Text(last)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
            }
            HStack {
                Button("Open note") { showMainWindow(openWindow) }
                    .buttonStyle(PillButtonStyle(kind: .soft, compact: true))
                Spacer()
                Button {
                    Task { await state.stopMeeting() }
                } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
            }
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            DancingBars(level: level, height: 12)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}
