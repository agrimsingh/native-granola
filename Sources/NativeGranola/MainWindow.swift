import GranolaCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            MeetingList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if state.recorder.isRecording {
                            Button { Task { await state.stopMeeting() } } label: {
                                Label("Stop", systemImage: "stop.circle.fill")
                            }
                            .tint(Theme.danger)
                        } else {
                            Button { Task { await state.startMeeting() } } label: {
                                Label("New note", systemImage: "square.and.pencil")
                            }
                            .disabled(state.recorder.state == .preparing)
                            .help("New note")
                        }
                    }
                }
        } detail: {
            if let meeting = state.selectedMeeting {
                MeetingDetailView(meetingID: meeting.id)
                    .id(meeting.id)
            } else {
                EmptyDetail()
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search notes and transcripts")
        .onChange(of: state.searchText) { state.runSearch() }
        .tint(Theme.accentFill)
    }
}

private struct EmptyDetail: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 12) {
            Text("Your meeting notes live here")
                .font(Theme.serif(28))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
            Text("Start a note when a call begins. Native Granola transcribes both sides of the conversation and writes up the notes when you're done.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button {
                Task { await state.startMeeting() }
            } label: {
                Label("Start new note", systemImage: "square.and.pencil")
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .disabled(state.recorder.isRecording || state.recorder.state == .preparing)
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

struct MeetingList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedMeetingID) {
            if !state.searchText.isEmpty {
                ForEach(state.searchHits, id: \.self) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.meetingTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(snippet(hit.snippet)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        Text(hit.meetingStartedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(hit.meetingID)
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, isRecording: state.recorder.isRecording && state.recorder.meeting?.id == meeting.id)
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) { state.delete(meeting) }
                                }
                        }
                    }
                }
            }
        }
        .overlay {
            if !state.searchText.isEmpty && state.searchHits.isEmpty {
                SidebarMessage(title: "No results", detail: "Nothing in your notes or transcripts matches “\(state.searchText)”.")
            } else if state.searchText.isEmpty && state.meetings.isEmpty {
                SidebarMessage(title: "No notes yet", detail: "Notes from your calls will show up here.")
            }
        }
    }

    private func snippet(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: state.meetings) { meeting -> String in
            if calendar.isDateInToday(meeting.startedAt) { return "Today" }
            if calendar.isDateInYesterday(meeting.startedAt) { return "Yesterday" }
            return meeting.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return grouped
            .map { (title: $0.key, meetings: $0.value) }
            .sorted { ($0.meetings.first?.startedAt ?? .distantPast) > ($1.meetings.first?.startedAt ?? .distantPast) }
    }
}

private struct SidebarMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isRecording {
                DancingBars(level: max(state.recorder.levels[.microphone] ?? 0, state.recorder.levels[.system] ?? 0),
                            height: 11)
            } else if meeting.enhancedNotes != nil {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Has AI notes")
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let time = meeting.startedAt.formatted(date: .omitted, time: .shortened)
        return meeting.attendees.isEmpty ? time : "\(time) · \(People.short(meeting.attendees))"
    }
}
