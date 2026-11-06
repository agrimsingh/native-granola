import GranolaAudio
import GranolaCore
import SwiftUI

typealias GranolaAudioRecorderRef = MeetingRecorder

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    Label("Start new note", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.recorder.state == .preparing)
            }
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            ExtraMenuSections()
            recent
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Native Granola").font(.headline)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(recent)) { meeting in
                    Button {
                        state.selectedMeetingID = meeting.id
                        showMainWindow(openWindow)
                    } label: {
                        HStack {
                            Text(meeting.title).lineLimit(1)
                            Spacer()
                            Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open notes") { showMainWindow(openWindow) }
            Spacer()
            Button {
                NSApp.activate()
                openSettings()
            } label: { Image(systemName: "gearshape") }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
            .help("Quit")
        }
        .buttonStyle(.borderless)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(meeting.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Transcript.timestamp(context.date.timeIntervalSince(meeting.startedAt)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                LevelMeter(label: "Me", level: recorder.levels[.microphone] ?? 0)
                LevelMeter(label: "Them", level: recorder.levels[.system] ?? 0)
            }
            if let last = recorder.volatileText.values.first ?? recorder.segments.last?.text {
                Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Open") { showMainWindow(openWindow) }
                Spacer()
                Button(role: .destructive) {
                    Task { await state.stopMeeting() }
                } label: { Label("Stop", systemImage: "stop.fill") }
                .tint(.red)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: geo.size.width * CGFloat(min(1, sqrt(Double(level)) * 2.5)))
                }
            }
            .frame(height: 5)
        }
    }
}
